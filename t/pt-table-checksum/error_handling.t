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

$ENV{PERCONA_TOOLKIT_TEST_USE_DSN_NAMES} = 1;

use PerconaTest;
use Sandbox;
use SqlModes;
require "$trunk/bin/pt-table-checksum";

my $dp = new DSNParser(opts=>$dsn_opts);
my $sb = new Sandbox(basedir => '/tmp', DSNParser => $dp);
my $source_dbh = $sb->get_dbh_for('source');
my $replica1_dbh = $sb->get_dbh_for('replica1');

if ( !$source_dbh ) {
   plan skip_all => 'Cannot connect to sandbox source';
}
elsif ( !$replica1_dbh ) {
   plan skip_all => 'Cannot connect to sandbox replica';
}

# The sandbox servers run with lock_wait_timeout=3 and it's not dynamic
# so we need to specify --set-vars innodb_lock_wait_timeout=3 else the tool will die.
# And --max-load "" prevents waiting for status variables.
my $source_dsn = 'h=127.1,P=12345,u=msandbox,p=msandbox';
my @args       = ($source_dsn, qw(--set-vars innodb_lock_wait_timeout=3), '--max-load', ''); 
my $output;
my $exit_status;

$sb->create_dbs($source_dbh, [qw(test)]);

# #############################################################################
# Issue 81: put some data that's too big into the boundaries table
# #############################################################################

# Frank : not sure what this test is trying to do.
# Inserting a truncated value in the boundary column should be fatal...no?
# It actually IS fatal with STRICT tables mode (mysql 5.7+)
# Since the idea is probably to test warning handling, we'll turn off STRICT
# for the next two tests.

my $modes = new SqlModes($source_dbh, global=>1);
$modes->del('STRICT_TRANS_TABLES','STRICT_ALL_TABLES');

$sb->load_file('source', 't/pt-table-checksum/samples/checksum_tbl_truncated.sql');

$output = output(
   sub { pt_table_checksum::main(@args,
      qw(--replicate test.truncated_checksums -t sakila.film_category),
      qw(--chunk-time 0 --chunk-size 100) ) },
   stderr => 1,
);
#1
like(
   $output,
   qr/MySQL error 1265: Data truncated/,
   "MySQL error 1265: Data truncated for column"
);
#2
my (@errors) = $output =~ m/error/;
is(
   scalar @errors,
   1,
   "Only one warning for MySQL error 1265"
);

$modes->restore_original_modes();

# ############################################################################
# Lock wait timeout
# ############################################################################
$source_dbh->do('use sakila');
$source_dbh->do('begin');
$source_dbh->do('select * from city for update');

$output = output(
   sub { $exit_status = pt_table_checksum::main(@args, qw(-t sakila.city)) },
   stderr => 1,
);

my $original_output;
($output, $original_output) = PerconaTest::normalize_checksum_results($output);
#3
like(
   $original_output,
   qr/Lock wait timeout exceeded/,
   "Warns about lock wait timeout"
);
#4
like(
   $output,
   qr/^0 0 0 0 1 1 sakila.city/m,
   "Skips chunk that times out"
);

is(
   $exit_status,
   32,
   "Exit 32 (SKIP_CHUNK)"
);

# Lock wait timeout for sandbox servers is 3s, so sleep 4 then commit
# to release the lock.  That should allow the checksum query to finish.
my ($id) = $source_dbh->selectrow_array('select connection_id()');
system("sleep 4 ; /tmp/12345/use -e 'KILL $id' >/dev/null");

$output = output(
   sub { pt_table_checksum::main(@args, qw(-t sakila.city)) },
   stderr => 1,
   trf    => sub { return PerconaTest::normalize_checksum_results(@_) },
);

unlike(
   $output,
   qr/Lock wait timeout exceeded/,
   "Lock wait timeout retried"
);

like(
   $output,
   qr/^0 0 600 0 1 0 sakila.city/m,
   "Checksum retried after lock wait timeout"
);

# Reconnect to source since we just killed ourself.
$source_dbh = $sb->get_dbh_for('source');

# #############################################################################
# pt-table-checksum breaks replication if a replica table is missing or different
# https://bugs.launchpad.net/percona-toolkit/+bug/1009510
# #############################################################################

# Just re-using this simple table.
$sb->load_file('source', "t/pt-table-checksum/samples/600cities.sql");

$source_dbh->do("SET SQL_LOG_BIN=0");
$source_dbh->do("ALTER TABLE test.t ADD COLUMN col3 int");
$source_dbh->do("SET SQL_LOG_BIN=1");

$output = output(
   sub { $exit_status = pt_table_checksum::main(@args,
      qw(-t test.t)) },
   stderr => 1,
);

like(
   $output,
   qr/Skipping table test.t/,
   "Skip table missing column on replica (bug 1009510)"
);

like(
   $output,
   qr/replica h=127.0.0.1,P=12346 is missing these columns: col3/,
   "Checked replica1 (bug 1009510)"
);

like(
   $output,
   qr/replica h=127.0.0.1,P=12347 is missing these columns: col3/,
   "Checked replica2 (bug 1009510)"
);

is(
   $exit_status,
   64,  # SKIP_TABLE
   "Non-zero exit status (bug 1009510)"
);

$output = output(
   sub { $exit_status = pt_table_checksum::main(@args,
      qw(-t test.t), '--columns', 'id,city') },
   stderr => 1,
);

unlike(
   $output,
   qr/Skipping table test.t/,
   "Doesn't skip table missing column on replica with --columns (bug 1009510)"
);

is(
   $exit_status,
   0,
   "Zero exit status with --columns (bug 1009510)"
);

# Use the --replicate table created by the previous ^ tests.

# Create a user that can't create the --replicate table.
diag(`/tmp/12345/use -uroot -pmsandbox < $trunk/t/lib/samples/ro-checksum-user.sql 2>&1`);
diag(`/tmp/12345/use -uroot -pmsandbox -e "GRANT REPLICATION CLIENT, REPLICATION SLAVE ON *.* TO ro_checksum_user\@'%'" 2>&1`);

# Remove the --replicate table from replica1 and replica2,
# so it's only on the source...
$replica1_dbh->do("DROP DATABASE percona");
$sb->wait_for_replicas;

$output = output(
   sub { $exit_status = pt_table_checksum::main(
      "h=127.1,u=ro_checksum_user,p=msandbox,P=12345,s=1",
      qw(--set-vars innodb_lock_wait_timeout=3 -t mysql.user)) },
   stderr => 1,
);

like(
   $output,
   qr/database percona exists on the source/,
   "CREATE DATABASE error and db is missing on replicas (bug 1039569)"
);

diag(`/tmp/12345/use -uroot -pmsandbox -e "DROP USER ro_checksum_user\@'%'" 2>&1`);

# #############################################################################
# Done.
# #############################################################################
$sb->wipe_clean($source_dbh);
ok($sb->ok(), "Sandbox servers") or BAIL_OUT(__FILE__ . " broke the sandbox");
done_testing;
