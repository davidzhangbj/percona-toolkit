#!/usr/bin/env perl

BEGIN {
   die "The PERCONA_TOOLKIT_BRANCH environment variable is not set.\n"
      unless $ENV{PERCONA_TOOLKIT_BRANCH} && -d $ENV{PERCONA_TOOLKIT_BRANCH};
   unshift @INC, "$ENV{PERCONA_TOOLKIT_BRANCH}/lib";
};

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use Time::HiRes qw(sleep);
use Test::More;

use PerconaTest;
use Sandbox;
require "$trunk/bin/pt-fk-error-logger";

require VersionParser;
my $dp = new DSNParser(opts=>$dsn_opts);
my $sb = new Sandbox(basedir => '/tmp', DSNParser => $dp);
my $dbh = $sb->get_dbh_for('source');

if ( !$dbh ) {
   plan skip_all => 'Cannot connect to sandbox source';
}
elsif ( $sandbox_version lt '8.0' ) {
   plan skip_all => "Requires MySQL 8.0 or newer";
}

$sb->create_dbs($dbh, [qw(test)]);

my ($output, $exit_code);
my $cnf  = '/tmp/12345/my.sandbox.cnf';
my $cmd  = "$trunk/bin/pt-fk-error-logger -F $cnf ";
my @args = qw(--iterations 1);

$sb->do_as_root(
   'source',
   q/CREATE USER IF NOT EXISTS sha256_user@'%' IDENTIFIED WITH caching_sha2_password BY 'sha256_user%password' REQUIRE SSL/,
   q/GRANT ALL ON test.* TO sha256_user@'%'/,
   q/GRANT PROCESS ON *.* TO sha256_user@'%'/,
);

$sb->load_file('source', 't/pt-fk-error-logger/samples/fke_tbl.sql', 'test');

# #########################################################################
# Test saving foreign key errors to --dest.
# #########################################################################

# First, create a foreign key error.
`/tmp/12345/use -D test < $trunk/t/pt-fk-error-logger/samples/fke.sql 1>/dev/null 2>/dev/null`;

($output, $exit_code) = full_output(
   sub {
      pt_fk_error_logger::main(@args, 'h=127.1,P=12345,u=sha256_user,p=sha256_user%password,s=0'),
   },
   stderr => 1,
);

isnt(
   $exit_code,
   0,
   "Error raised when SSL connection is not used"
) or diag($output);

like(
   $output,
   qr/Authentication plugin 'caching_sha2_password' reported error: Authentication requires secure connection./,
   'Secure connection error raised when no SSL connection used'
) or diag($output);

($output, $exit_code) = full_output(
   sub {
      pt_fk_error_logger::main(@args, 'h=127.1,P=12345,u=sha256_user,p=sha256_user%password,s=1'),
   },
   stderr => 1,
);

is(
   $exit_code,
   0,
   "No error for user, identified with caching_sha2_password"
) or diag($output);

unlike(
   $output,
   qr/Authentication plugin 'caching_sha2_password' reported error: Authentication requires secure connection./,
   'No secure connection error'
) or diag($output);

like(
   $output,
   qr/Foreign key constraint fails/,
   "Prints fk error by default"
);

# #############################################################################
# Done.
# #############################################################################
$sb->do_as_root('source', q/DROP USER 'sha256_user'@'%'/);

$sb->wipe_clean($dbh);
ok($sb->ok(), "Sandbox servers") or BAIL_OUT(__FILE__ . " broke the sandbox");
done_testing;
