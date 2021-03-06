# Copyright (c) 2020 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program (see the file COPYING); if not, write to the
# Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA
#
package BSSrcServer::SQLite;

use strict;

use BSConfiguration;
use BSUtil;
use BSDB;
use Data::Dumper;

use DBI qw(:sql_types);
use DBD::SQLite;

use JSON::XS ();


my $sqlitedb = "$BSConfig::bsdir/db/sqlite";

sub dobinds {
  my ($sh, $start, @binds) = @_;
  $sh->bind_param($start++, @$_) for @binds;
}

sub dbdo {
  my ($h, $statement) = @_;
  $statement =~ s/^\s*//s;
  $h->do($statement) || die($h->errstr);
}

sub dbdo_bind {
  my ($h, $statement, @binds) = @_;
  $statement =~ s/^\s*//s;
  my $sh = $h->prepare($statement) || die($h->errstr);
  dobinds($sh, 1, @binds);
  $sh->execute() || die($sh->errstr);
  return $sh;
}

sub connectdb {
  my ($db) = @_;
  mkdir_p($sqlitedb);
  my $h = DBI->connect("dbi:SQLite:dbname=$sqlitedb/published");
  $h->{AutoCommit} = 1;
  $db->{'sqlite'} = $h;
  createtables_binary($db, $h);
  createtables_pattern($db, $h) if $db->{'table'} eq 'pattern';
  return $h;
}

my %tables = (
  'binary' => { map {$_ => 1} qw {package name} },
  'pattern' => { map {$_ => 1} qw {package name summary description type} },
);

sub createtables_binary {
  my ($db, $h) = @_;
  dbdo($h, 'PRAGMA foreign_keys = OFF');
  dbdo($h, <<'EOS');
CREATE TABLE IF NOT EXISTS prp_ext(
  id INTEGER PRIMARY KEY,
  path TEXT,
  json TEXT,
  project TEXT,
  UNIQUE(path)
)
EOS
  dbdo($h, <<'EOS');
CREATE TABLE IF NOT EXISTS binary(
  prp_ext INTEGER,
  name TEXT,
  path TEXT,
  package TEXT,
  FOREIGN KEY(prp_ext) REFERENCES prp_ext(id)
)
EOS
  dbdo($h, <<'EOS');
CREATE INDEX IF NOT EXISTS prp_ext_idx_path on prp_ext(path);
EOS
  dbdo($h, <<'EOS');
CREATE INDEX IF NOT EXISTS prp_ext_idx_project on prp_ext(project);
EOS
  dbdo($h, <<'EOS');
CREATE INDEX IF NOT EXISTS binary_idx_name on binary(name);
EOS
  dbdo($h, <<'EOS');
CREATE INDEX IF NOT EXISTS binary_idx_prp_ext on binary(prp_ext);
EOS
}

sub createtables_pattern {
  my ($db, $h) = @_;
  return if $db->{'sqlite_pattern_created'};
  dbdo($h, <<'EOS');
CREATE TABLE IF NOT EXISTS pattern(
  prp_ext INTEGER,
  path TEXT,
  package TEXT,
  json TEXT,
  name TEXT,
  summary TEXT,
  description TEXT,
  type TEXT,
  FOREIGN KEY(prp_ext) REFERENCES prp_ext(id)
)
EOS
  dbdo($h, <<'EOS');
CREATE INDEX IF NOT EXISTS pattern_idx_name on pattern(name);
EOS
  dbdo($h, <<'EOS');
CREATE INDEX IF NOT EXISTS pattern_idx_prp_ext on pattern(prp_ext);
EOS
  $db->{'sqlite_pattern_created'} = 1;
}

###########################################################################

sub prpext2id {
  my ($h, $prp_ext, $repoinfo) = @_;
  if (!$repoinfo) {
    my @ary = $h->selectrow_array('SELECT id from prp_ext WHERE path = ?', undef, $prp_ext);
    return $ary[0];
  }
  my @p = split('/', $prp_ext);
  splice(@p, 0, 2, "$p[0]$p[1]") while @p > 1 && $p[0] =~ /:$/;
  my $project = shift @p;

  my %i = %$repoinfo;
  delete $i{$_} for qw{binaryorigins state code starttime endtime publishid};
  my $json = JSON::XS->new->utf8->canonical->encode(\%i);

  my @ary = $h->selectrow_array('SELECT id,json from prp_ext WHERE path = ?', undef, $prp_ext);
  if (!$ary[0]) {
    dbdo_bind($h, 'INSERT OR IGNORE INTO prp_ext(path,json,project) VALUES(?,?,?)', [ $prp_ext ], [ $json ], [ $project ]);
    @ary = $h->selectrow_array('SELECT id from prp_ext where path = ?', undef, $prp_ext);
  } elsif (!$ary[1] || $ary[1] ne $json) {
    dbdo_bind($h, 'UPDATE prp_ext SET json = ?, project = ? WHERE path = ?', [ $json ], [ $project ], [ $prp_ext ]);
  }
  die("could not insert new prp_ext '$prp_ext'\n") unless $ary[0];
  return $ary[0];
}

###########################################################################

sub binarypath2name {
  my ($path) = @_;
  $path =~ s/.*\///;
  return $1 if $path =~ /^(.*)-[^-]+-[^-]+\.[^\.]+\.rpm$/;
  return $1 if $path =~ /^(.*)_[^_]+_[^_]+\.deb$/;
  return $1 if $path =~ /^(.*)-[^-]+-[^-]+-[^-]+\.pkg\.tar\.(?:xz|gz|zstd)$/;
  return undef;
}

sub updatedb_deleterepo {
  my ($db, $prp) = @_;

  my $prp_ext = $prp;
  $prp_ext =~ s/:/:\//g;
  my $h = $db->{'sqlite'} || connectdb($db);

  my $prp_ext_id = prpext2id($h, $prp_ext);
  return unless $prp_ext_id;

  createtables_pattern($db, $h) unless $db->{'sqlite_pattern_created'};
  $h->begin_work() || die($h->errstr);
  dbdo_bind($h, 'DELETE FROM binary WHERE prp_ext = ?', [ $prp_ext_id, SQL_INTEGER ]);
  dbdo_bind($h, 'DELETE FROM pattern WHERE prp_ext = ?', [ $prp_ext_id, SQL_INTEGER ]);
  dbdo_bind($h, 'DELETE FROM prp_ext WHERE id = ?', [ $prp_ext_id, SQL_INTEGER ]);
  $h->commit() || die $h->errstr;
}

sub updatedb_repoinfo {
  my ($db, $prp, $repoinfo) = @_;

  return updatedb_deleterepo($db, $prp) unless $repoinfo;

  my $prp_ext = $prp;
  $prp_ext =~ s/:/:\//g;

  my $h = $db->{'sqlite'} || connectdb($db);
  my $sh;

  my $prp_ext_id = prpext2id($h, $prp_ext, $repoinfo);
  my $binaryorigins = $repoinfo->{'binaryorigins'};
  my @bins = sort keys %{$binaryorigins || {}};

  if (!@bins) {
    $h->begin_work() || die($h->errstr);
    dbdo_bind($h, 'DELETE FROM binary WHERE prp_ext = ?', [ $prp_ext_id, SQL_INTEGER ]);
    $h->commit() || die $h->errstr;
    return;
  }

  # start transaction
  $h->begin_work() || die($h->errstr);

  # get old data
  $sh = dbdo_bind($h, 'SELECT rowid,name,path FROM binary WHERE prp_ext = ?', [ $prp_ext_id, SQL_INTEGER ]);
  my ($rowid, $name, $path);
  $sh->bind_columns(\$rowid, \$name, \$path);
  my %old;
  $old{"$name/$path"} = $rowid while $sh->fetch();
  die($sh->errstr) if $sh->err();

  # add new entries
  $sh = undef;
  for my $path (@bins) {
    my $name = binarypath2name($path);
    next unless defined $name;
    if (exists($old{"$name/$path"})) {
      $old{"$name/$path"} = 0;
      next;
    }
    if (!$sh) {
      $sh = $h->prepare('INSERT INTO binary(prp_ext,name,path,package) VALUES(?,?,?,?)') || die($h->errstr);
      $sh->bind_param(1, $prp_ext_id, SQL_INTEGER);
    }
    $sh->bind_param(2, $name);
    $sh->bind_param(3, $path);
    $sh->bind_param(4, $binaryorigins->{$path});
    $sh->execute() || die($sh->errstr);
  }

  # get rid of old entries
  my @del = sort {$a <=> $b} grep {$_} values %old;
  if (@del) {
    $sh = $h->prepare('DELETE FROM binary WHERE rowid = ?') || die($h->errstr);
    for my $rowid (@del) {
      $sh->bind_param(1, $rowid, SQL_INTEGER);
      $sh->execute() || die($sh->errstr);
    }
  }

  # finish transaction
  $h->commit() || die $h->errstr;
}

sub updatedb_patterninfo {
  my ($db, $prp, $patterninfo) = @_;

  my $prp_ext = $prp;
  $prp_ext =~ s/:/:\//g;

  my $h = $db->{'sqlite'} || connectdb($db);

  my $prp_ext_id = prpext2id($h, $prp_ext);
  return unless $prp_ext_id;

  createtables_pattern($db, $h) unless $db->{'sqlite_pattern_created'};

  my @pats = sort keys %{$patterninfo || {}};
  if (!@pats) {
    $h->begin_work() || die($h->errstr);
    dbdo_bind($h, 'DELETE FROM pattern WHERE prp_ext = ?', [ $prp_ext_id, SQL_INTEGER ]);
    $h->commit() || die $h->errstr;
    return;
  }
  # start transaction
  $h->begin_work() || die($h->errstr);
  my $sh;

  # get old data
  $sh = dbdo_bind($h, 'SELECT rowid,path,json FROM pattern WHERE prp_ext = ?', [ $prp_ext_id, SQL_INTEGER ]);
  my ($rowid, $path, $json);
  $sh->bind_columns(\$rowid, \$path, \$json);
  my %old;
  $old{"$path/$json"} = $rowid while $sh->fetch();
  die($sh->errstr) if $sh->err();

  # add new entries
  $sh = undef;
  for my $path (@pats) {
    my $pat = $patterninfo->{$path};
    $json = JSON::XS->new->utf8->canonical->encode($pat);
    if (exists($old{"$path/$json"})) {
      $old{"$path/$json"} = 0;
      next;
    }
    if (!$sh) {
      $sh = $h->prepare('INSERT INTO pattern(prp_ext,path,package,json,name,summary,description,type) VALUES(?,?,?,?,?,?,?,?)') || die($h->errstr);
      $sh->bind_param(1, $prp_ext_id, SQL_INTEGER);
    }
    $sh->bind_param(2, $path);
    $sh->bind_param(3, $pat->{'package'} || '_pattern');
    $sh->bind_param(4, $json);
    $sh->bind_param(5, $pat->{'name'});
    $sh->bind_param(6, $pat->{'summary'});
    $sh->bind_param(7, $pat->{'description'});
    $sh->bind_param(8, $pat->{'type'});
    $sh->execute() || die($sh->errstr);
  }

  # get rid of old entries
  my @del = sort {$a <=> $b} grep {$_} values %old;
  if (@del) {
    $sh = $h->prepare('DELETE FROM pattern WHERE rowid = ?') || die($h->errstr);
    for my $rowid (@del) {
      $sh->bind_param(1, $rowid, SQL_INTEGER);
      $sh->execute() || die($sh->errstr);
    }
  }

  # finish transaction
  $h->commit() || die $h->errstr;
}

###########################################################################
#
# Search helpers
#

our %binarykey2package;		# cache for key->package translation

sub getrepoinfo {
  my ($db, $prp_ext) = @_;
  my $h = $db->{'sqlite'} || connectdb($db);
  my @ary = $h->selectrow_array('SELECT id,json from prp_ext WHERE path = ?', undef, $prp_ext);
  return undef unless $ary[1];
  return JSON::XS::decode_json($ary[1]);
}

sub getrepoorigins {
  my ($db, $prp_ext) = @_;
  my $h = $db->{'sqlite'} || connectdb($db);
  my $prp_ext_id = prpext2id($h, $prp_ext);
  return undef unless $prp_ext_id;
  my $table = $db->{'table'};
  my %binaryorigins;
  my $sh = dbdo_bind($h, "SELECT path,package FROM $table WHERE prp_ext = ?", [ $prp_ext_id, SQL_INTEGER ]);
  my ($path, $packid) = @_;
  $sh->bind_columns(\$path, \$packid);
  $binaryorigins{$path} = $packid while $sh->fetch();
  die($sh->errstr) if $sh->err();
  return \%binaryorigins;
}

sub getprojectkeys {
  my ($db, $projid) = @_;
  my $h = $db->{'sqlite'} || connectdb($db);
  if (!$projid) {
    my $sh = dbdo_bind($h, 'SELECT project FROM prp_ext');
    $sh->bind_columns(\$projid);
    my @res;
    push @res, $projid while $sh->fetch();
    die($sh->errstr) if $sh->err();
    return sort(@res);
  }
  my $table = $db->{'table'};
  my $sh = dbdo_bind($h, "SELECT prp_ext.path,$table.path,package FROM $table LEFT JOIN prp_ext ON prp_ext.id = $table.prp_ext WHERE prp_ext.project = ?", [ $projid ]);
  my ($prp_ext_path, $bin_path, $package);
  $sh->bind_columns(\$prp_ext_path, \$bin_path, \$package);
  my @res;
  while ($sh->fetch()) {
    my $key = "$prp_ext_path/$bin_path";
    $binarykey2package{$key} = $package if $table eq 'binary';
    push @res, $key;
  }
  die($sh->errstr) if $sh->err();
  return sort(@res);
}

sub getrecord {
  my ($db, $prp_ext, $path) = @_;
  my $h = $db->{'sqlite'} || connectdb($db);
  my $prp_ext_id = prpext2id($h, $prp_ext);
  return undef unless $prp_ext_id;
  my $table = $db->{'table'};
  return undef if $table eq 'binary';		# no json element in binary
  my @ary = $h->selectrow_array("SELECT $table.json FROM $table LEFT JOIN prp_ext ON prp_ext.id = $table.prp_ext WHERE prp_ext.path = ? AND $table.path  = ?", undef, $prp_ext, $path);
  return $ary[0] ? JSON::XS::decode_json($ary[0]) : undef;
}

###########################################################################
#
# BSDB query interface
#

sub opendb {
  my ($dbpath, $table) = @_;
  die("unsupported table: $table\n") unless $tables{$table};
  my $db = { 'dir' => $dbpath, 'table' => $table, 'sqlite_cols' => $tables{$table} };
  return bless $db;
}

sub fetch {
  my ($db, $key) = @_;
  return $db->{'fetch'}->($db, $key) if $db->{'fetch'};
  die("Cannot fetch data set in query\n");
}

sub hint2prefixes {
  my ($hint, $hintval) = @_;
  my @prefixes;
  if ($hint eq 'starts-with') {
    push @prefixes, $1 if $hintval =~ /^([\000-\176]+)/s;
  } elsif ($hint eq 'starts-with-ic' || $hint eq 'equals-ic') {
    return () unless $hintval =~ /^([\000-\176]+)/s;
    push @prefixes, '';
    for my $c (split(//, substr($1, 0, 2))) {
      @prefixes = map {($_.lc($c), $_.uc($c))} @prefixes;
    }
    @prefixes = sort(keys %{ { map {$_ => 1} @prefixes } });
  }
  return @prefixes;
}

sub values {
  my ($db, $path, $lkeys, $hint, $hintval) = @_;
  if ($db->{'indexfunc'} && $db->{'indexfunc'}->{$path}) {
    return $db->{'indexfunc'}->{$path}->($db, $path, undef, $lkeys);
  }
  if (($db->{'noindex'} && $db->{'noindex'}->{$path}) || $db->{'noindexatall'} || ($lkeys && $db->{'cheapfetch'})) {
    return BSDB::values($db, $path, $lkeys);
  }

  my $table = $db->{'table'};
  die("unsupported path for $table table: $path\n") unless $db->{'sqlite_cols'}->{$path};

  # get all values from a table column
  my $h = $db->{'sqlite'} || connectdb($db);

  # try to limit the search to some prefixes
  my @prefixsql;
  my @prefixargs;
  if ($hint && defined($hintval)) {
    for my $p (hint2prefixes($hint, $hintval)) {
      next if $p eq '';
      push @prefixsql, "$path >= ? AND $path < ?";
      push @prefixargs, $p, substr($p, 0, -1).chr(ord(substr($p, -1, 1)) + 1);
    }
  }

  # sqlite switches to full index search when using too many ORs with DISTINCT, so use multiple selects instead
  if (@prefixsql > 1) {
    my %res;
    while (@prefixsql) {
      my $s = shift @prefixsql;
      my @a = splice(@prefixargs, 0, 2);
      my $ary = $h->selectcol_arrayref("SELECT DISTINCT $path FROM $table WHERE $s", undef, @a) || die($h->errstr);
      $res{$_} = 1 for @$ary;
    }
    return sort keys %res;
  }

  my $ary;
  if (@prefixsql) {
    $ary = $h->selectcol_arrayref("SELECT DISTINCT $path FROM $table WHERE (".join(') OR (', @prefixsql).")", undef, @prefixargs) || die($h->errstr);
  } else {
    $ary = $h->selectcol_arrayref("SELECT DISTINCT $path FROM $table") || die($h->errstr);
  }
  return sort(@$ary);
}

sub keys {
  my ($db, $path, $value, $lkeys) = @_;
  if (!defined($path)) {
    return @$lkeys if $lkeys;
    die("413 refusing to get all keys\n");
  }
  if ($db->{'indexfunc'} && $db->{'indexfunc'}->{$path}) {
    return $db->{'indexfunc'}->{$path}->($db, $path, $value, $lkeys);
  }
  if (($db->{'noindex'} && $db->{'noindex'}->{$path}) || $db->{'noindexatall'}) {
    return BSDB::keys($db, $path, $value, $lkeys);
  }

  my $table = $db->{'table'};
  die("unsupported path for $table table: $path\n") unless $db->{'sqlite_cols'}->{$path};

  # get all keys for a table column
  my $h = $db->{'sqlite'} || connectdb($db);
  my $sh = dbdo_bind($h, "SELECT prp_ext.path,$table.path,package FROM $table LEFT JOIN prp_ext ON prp_ext.id = $table.prp_ext WHERE $path = ?", [ $value ]);
  my ($prp_ext_path, $bin_path, $package);
  $sh->bind_columns(\$prp_ext_path, \$bin_path, \$package);
  my @res;
  while ($sh->fetch()) {
    my $key = "$prp_ext_path/$bin_path";
    $binarykey2package{$key} = $package if $table eq 'binary';
    push @res, $key;
  }
  die($sh->errstr) if $sh->err();
  return sort(@res);
}

1;
