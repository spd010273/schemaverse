#!/usr/bin/perl
use utf8;
use strict;
use warnings;

use DBI;
use Getopt::Std;

our( $opt_p );
die( "Invalid arguments" ) unless( getopts( 'p:' ) );

my $password = $opt_p;
die( "No password" ) unless( $password and length( $password > 0 ) );
use constant LDBASE_HOSTNAME     => 'localhost';
use constant LDBASE_PORT         => '5432';
use constant LDBASE_TYPE         => 'Pg';
use constant LDBASE_SID          => 'postgres';
use constant LDBASE_USERNAME     => 'postgres';
use constant LDBASE_PASSWORD     => $password;
use constant LDBASE_CONNECT_PERL => 'dbi:'. LDBASE_TYPE .':dbname='.LDBASE_SID.';host='.LDBASE_HOSTNAME.';port='.LDBASE_PORT;

use constant GDBASE_HOSTNAME     => 'localhost';
use constant GDBASE_PORT         => '5432';
use constant GDBASE_TYPE         => 'Pg';
use constant GDBASE_SID          => 'schemaverse';
use constant GDBASE_USERNAME     => 'schemaverse';
use constant GDBASE_PASSWORD     => $password;
use constant GDBASE_CONNECT_PERL => 'dbi:'. GDBASE_TYPE .':dbname='.GDBASE_SID.';host='.GDBASE_HOSTNAME.';port='.GDBASE_PORT;

open( FILE, '<pid' ) or die( 'Could not open pid file!' );

while( my $line = <FILE> )
{
    my $pid     = $line;
       $pid     =~ s/\s.*$//;
    my $script  = $line;
       $script  =~ s/^\d+\s//;
       chomp( $script );
       chomp( $pid );
    
    print "killing $pid - $script\n";
    system( "kill -9 $pid" );
}

close FILE;
unlink( 'pid' ) or die( 'couldnt delete pid file' );
my $handle = DBI->connect( LDBASE_CONNECT_PERL, LDBASE_USERNAME, LDBASE_PASSWORD, { AutoCommit => 1, ShowErrorStatement => 1 } );
   $handle->do( 'SELECT pg_terminate_backend( pid ) FROM pg_stat_activity WHERE datname = \'schemaverse\'' );
   $handle->do( 'DROP DATABASE schemaverse' );
   $handle->do( 'DROP ROLE ai1' );
   $handle->do( 'DROP ROLE ai2' );
   $handle->do( 'DROP ROLE ai3' );
   $handle->do( 'DROP ROLE IF EXISTS spd010273'   );
   $handle->do( 'DROP ROLE schemaverse' );
   $handle->do( 'DROP ROLE players'     );

   $handle->do( 'CREATE ROLE schemaverse WITH PASSWORD \'$password\' NOINHERIT SUPERUSER CREATEDB CREATEROLE VALID UNTIL \'infinity\' LOGIN' );
   $handle->do( 'CREATE DATABASE schemaverse OWNER=schemaverse' );
   $handle->do( 'ALTER DATABASE schemaverse SET TABLESPACE ram' );

   $handle->disconnect();
system( 'psql -U schemaverse -d schemaverse -1 -f create.sql' ); 
sleep( 3 );
my $ghandle = DBI->connect( GDBASE_CONNECT_PERL, GDBASE_USERNAME, GDBASE_PASSWORD, { AutoCommit => 1, ShowErrorStatement => 1 } ) or die( 'Couldnt connect' );

$ghandle->do( 'SELECT COUNT(*) FROM planets' ) or die( 'dataload failed' );

# Create accounts
$ghandle->do( "INSERT INTO player( username, password ) VALUES ( \'spd010273\', \'$password\' )" );
$ghandle->do( 'INSERT INTO player( username, password ) VALUES ( \'ai1\', \'test\' )' );
$ghandle->do( 'INSERT INTO player( username, password ) VALUES ( \'ai2\', \'test\' )' );
$ghandle->do( 'INSERT INTO player( username, password ) VALUES ( \'ai3\', \'test\' )' );

my @scripts = qw( tic.pl ref.pl stat.pl );

open( FILE, '>pid' );
foreach my $script( @scripts )
{
    my $pid = fork();
    die "cannot fork: $!" unless( defined $pid );

    if( !$pid )
    {
        exec( "perl $script &> /tmp/$script.log &" );
        exit 0;
    }
    
    my $real_pid = `ps -ef | grep $script | grep -v grep | awk '{print \$2 }'`;
    chomp $real_pid; 
    print( FILE "$real_pid $script\n" );
}
close( FILE );
