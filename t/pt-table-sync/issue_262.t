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
use Sandbox;
require "$trunk/bin/pt-table-sync";

my $output;
my $dp = new DSNParser(opts=>$dsn_opts);
my $sb = new Sandbox(basedir => '/tmp', DSNParser => $dp);
my $source_dbh = $sb->get_dbh_for('source');
my $replica_dbh  = $sb->get_dbh_for('replica1');

if ( !$source_dbh ) {
   plan skip_all => 'Cannot connect to sandbox source';
}
elsif ( !$replica_dbh ) {
   plan skip_all => 'Cannot connect to sandbox replica';
}
else {
   plan tests => 2;
}

$sb->wipe_clean($source_dbh);
$sb->wipe_clean($replica_dbh);
$sb->create_dbs($source_dbh, [qw(test)]);

# #############################################################################
# Issue 262
# #############################################################################
$sb->create_dbs($source_dbh, ['foo']);
$sb->use('source', '-e "create table foo.t1 (i int)"');
$sb->use('source', '-e "SET SQL_LOG_BIN=0; insert into foo.t1 values (1)"');
$sb->use('replica1', '-e "truncate table foo.t1"');
$output = `$trunk/bin/pt-table-sync --no-check-replica --print h=127.1,P=12345,u=msandbox,p=msandbox -d mysql,foo h=127.1,P=12346 2>&1`;
like(
   $output,
   qr/INSERT INTO `foo`\.`t1`\(`i`\) VALUES \('1'\)/,
   'Does not die checking tables for triggers (issue 262)'
);

# #############################################################################
# Done.
# #############################################################################
$sb->wipe_clean($source_dbh);
$sb->wipe_clean($replica_dbh);
ok($sb->ok(), "Sandbox servers") or BAIL_OUT(__FILE__ . " broke the sandbox");
exit;
