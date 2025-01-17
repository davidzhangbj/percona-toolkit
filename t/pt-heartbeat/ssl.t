#!/usr/bin/env perl

BEGIN {
   die "The PERCONA_TOOLKIT_BRANCH environment variable is not set.\n"
      unless $ENV{PERCONA_TOOLKIT_BRANCH} && -d $ENV{PERCONA_TOOLKIT_BRANCH};
   unshift @INC, "$ENV{PERCONA_TOOLKIT_BRANCH}/lib";
};

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use Test::More;
use Data::Dumper;

use PerconaTest;
use Sandbox;
require "$trunk/bin/pt-heartbeat";

my $dp  = new DSNParser(opts=>$dsn_opts);
my $sb  = new Sandbox(basedir => '/tmp', DSNParser => $dp);
my $dbh = $sb->get_dbh_for('source');

if ( !$dbh ) {
   plan skip_all => 'Cannot connect to sandbox source';
}
elsif ( $sandbox_version lt '8.0' ) {
   plan skip_all => "Requires MySQL 8.0 or newer";
}

$sb->create_dbs($dbh, ['test']);

my ($output, $exit_code);
my $cnf       = '/tmp/12345/my.sandbox.cnf';
my $cmd       = "$trunk/bin/pt-heartbeat -F $cnf ";

$dbh->do('drop table if exists test.heartbeat');
$dbh->do(q{CREATE TABLE test.heartbeat (
             id int NOT NULL PRIMARY KEY,
             ts datetime NOT NULL
          ) ENGINE=MEMORY});
$sb->wait_for_replicas;

$sb->do_as_root(
   'source',
   q/CREATE USER IF NOT EXISTS sha256_user@'%' IDENTIFIED WITH caching_sha2_password BY 'sha256_user%password' REQUIRE SSL/,
   q/GRANT ALL ON test.* TO sha256_user@'%'/,
);

($output, $exit_code) = full_output(
   sub { pt_heartbeat::main("F=$cnf,h=127.1,P=12345,u=sha256_user,p=sha256_user%password,s=0",
      qw(-D test --check)) },
   stderr => 1,
);

isnt(
   $?,
   0,
   "Error raised when SSL connection is not used"
) or diag($output);

like(
   $output,
   qr/Authentication plugin 'caching_sha2_password' reported error: Authentication requires secure connection./,
   'Secure connection error raised when no SSL connection used'
) or diag($output);

($output, $exit_code) = full_output(
   sub { pt_heartbeat::main("F=$cnf,h=127.1,P=12345,u=sha256_user,p=sha256_user%password,s=1",
      qw(-D test --check)) },
   stderr => 1,
);

is(
   $?,
   0,
   "No error for user, identified with caching_sha2_password"
) or diag($output);

unlike(
   $output,
   qr/Authentication plugin 'caching_sha2_password' reported error: Authentication requires secure connection./,
   'No secure connection error'
) or diag($output);

my $row = $dbh->selectall_hashref('select * from test.heartbeat', 'id');
is(
   $row->{1}->{id},
   1,
   "Automatically inserts heartbeat row (issue 1292)"
);

# #############################################################################
# Done.
# #############################################################################
$sb->do_as_root('source', q/DROP USER 'sha256_user'@'%'/);

$sb->wipe_clean($dbh);
ok($sb->ok(), "Sandbox servers") or BAIL_OUT(__FILE__ . " broke the sandbox");

done_testing;
exit;
