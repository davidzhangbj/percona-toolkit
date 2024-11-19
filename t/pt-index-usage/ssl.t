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

use PerconaTest;
require "$trunk/bin/pt-index-usage";
require VersionParser;

use Sandbox;
my $dp  = new DSNParser(opts=>$dsn_opts);
my $sb  = new Sandbox(basedir => '/tmp', DSNParser => $dp);
my $dbh = $sb->get_dbh_for('source');

if ( !$dbh ) {
   plan skip_all => 'Cannot connect to sandbox source';
}
elsif ( $sandbox_version lt '8.0' ) {
   plan skip_all => "Requires MySQL 8.0 or newer";
}
elsif ( !@{ $dbh->selectall_arrayref("show databases like 'sakila'") } ) {
   plan skip_all => "Sakila database is not loaded";
}

my $cnf     = '/tmp/12345/my.sandbox.cnf';
my @args    = ('-F', $cnf);
my $samples = "t/pt-index-usage/samples/";
my ($output, $exit_code);

$sb->do_as_root(
   'source',
   q/CREATE USER IF NOT EXISTS sha256_user@'%' IDENTIFIED WITH caching_sha2_password BY 'sha256_user%password' REQUIRE SSL/,
   q/GRANT ALL ON sakila.* TO sha256_user@'%'/,
);

# This query doesn't use indexes so there's an unused PK and
# an unused secondary index.  Only the secondary index should
# be printed since dropping PKs is not suggested by default.

($output, $exit_code) = full_output(
   sub {
      pt_index_usage::main(
         @args,
         qw(--host=127.1 --port=12345 --user=sha256_user --password=sha256_user%password --mysql_ssl=0),
         "$trunk/$samples/slow001.txt")
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
      pt_index_usage::main(
         @args,
         qw(--host=127.1 --port=12345 --user=sha256_user --password=sha256_user%password --mysql_ssl=1),
         "$trunk/$samples/slow001.txt")
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
   qr/ALTER TABLE `sakila`.`film_text` DROP KEY `idx_title_description`; -- type:non-unique/,
   'A simple query that does not use any indexes',
) or diag($output);

# #############################################################################
# Done.
# #############################################################################
$sb->do_as_root('source', q/DROP USER 'sha256_user'@'%'/);

$sb->wipe_clean($dbh);
ok($sb->ok(), "Sandbox servers") or BAIL_OUT(__FILE__ . " broke the sandbox");
done_testing;
exit;
