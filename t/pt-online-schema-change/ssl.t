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

require "$trunk/bin/pt-online-schema-change";

my $dp = new DSNParser(opts=>$dsn_opts);
my $sb = new Sandbox(basedir => '/tmp', DSNParser => $dp);
my $source_dbh = $sb->get_dbh_for('source');
my $replica_dbh  = $sb->get_dbh_for('replica1');

if ( !$source_dbh ) {
   plan skip_all => 'Cannot connect to sandbox source';
}
elsif ( !$replica_dbh ) {
   plan skip_all => 'Cannot connect to sandbox replica1';
}
elsif ( $sandbox_version lt '8.0' ) {
   plan skip_all => "Requires MySQL 8.0 or newer";
}

# The sandbox servers run with lock_wait_timeout=3 and it's not dynamic
# so we need to specify --set-vars innodb_lock_wait_timeout=3 else the
# tool will die.
my $source_dsn = 'h=127.1,P=12345';
my @args       = (qw(--set-vars innodb_lock_wait_timeout=3));
my $output;
my $exit_code;
my $sample  = "t/pt-online-schema-change/samples/";

$sb->do_as_root(
   'source',
   q/CREATE USER IF NOT EXISTS sha256_user@'%' IDENTIFIED WITH caching_sha2_password BY 'sha256_user%password' REQUIRE SSL/,
   q/GRANT ALL ON test.* TO sha256_user@'%'/,
   q/GRANT REPLICATION SLAVE ON *.* TO sha256_user@'%'/,
   q/GRANT SUPER ON *.* TO sha256_user@'%'/,
);

# #############################################################################
# DROP PRIMARY KEY
# #############################################################################

$sb->load_file('source', "$sample/del-trg-bug-1103672.sql");

($output, $exit_code) = full_output(
   sub { pt_online_schema_change::main(@args,
      "$source_dsn,D=test,t=t1,u=sha256_user,p=sha256_user%password,s=0",
      "--alter", "drop primary key, add column _id int unsigned not null primary key auto_increment FIRST",
      qw(--execute --no-check-alter)),
   },
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
   sub { pt_online_schema_change::main(@args,
      "$source_dsn,D=test,t=t1,u=sha256_user,p=sha256_user%password,s=1",
      "--alter", "drop primary key, add column _id int unsigned not null primary key auto_increment FIRST",
      qw(--execute --no-check-alter)),
   },
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
   qr/Successfully altered `test`.`t1`/,
   "DROP PRIMARY KEY"
);

# #############################################################################
# Done.
# #############################################################################
$sb->do_as_root('source', q/DROP USER 'sha256_user'@'%'/);

$sb->wipe_clean($source_dbh);
ok($sb->ok(), "Sandbox servers") or BAIL_OUT(__FILE__ . " broke the sandbox");
done_testing;
