package Zonemaster::Backend::DB;

our $VERSION = '1.2.0';

use Moose::Role;

use 5.14.2;

use JSON::PP;
use Digest::MD5 qw(md5_hex);
use Encode;
use Log::Any qw( $log );

use Zonemaster::Engine::Profile;

requires qw(
  add_api_user_to_db
  add_batch_job
  create_db
  create_new_batch_job
  create_new_test
  from_config
  get_test_history
  get_test_params
  select_unfinished_tests
  test_progress
  test_results
  user_authorized
  user_exists_in_db
  get_relative_start_time
);

=head2 get_db_class

Get the database adapter class for the given database type.

Throws and exception if the database adapter class cannot be loaded.

=cut

sub get_db_class {
    my ( $class, $db_type ) = @_;

    my $db_class = "Zonemaster::Backend::DB::$db_type";

    require( "$db_class.pm" =~ s{::}{/}gr );
    $db_class->import();

    return $db_class;
}

sub user_exists {
    my ( $self, $user ) = @_;

    die Zonemaster::Backend::Error::Internal->new( reason => "username not provided to the method user_exists")
        unless ( $user );

    return $self->user_exists_in_db( $user );
}

sub add_api_user {
    my ( $self, $username, $api_key ) = @_;

    die Zonemaster::Backend::Error::Internal->new( reason => "username or api_key not provided to the method add_api_user")
        unless ( $username && $api_key );

    die Zonemaster::Backend::Error::Conflict->new( message => 'User already exists', data => { username => $username } )
        if ( $self->user_exists( $username ) );

    my $result = $self->add_api_user_to_db( $username, $api_key );

    die Zonemaster::Backend::Error::Internal->new( reason => "add_api_user_to_db not successful")
        unless ( $result );

    return $result;
}

# Standard SQL, can be here
sub get_test_request {
    my ( $self, $queue_label ) = @_;

    my $result_id;
    my $dbh = $self->dbh;

    my ( $id, $hash_id );
    if ( defined $queue_label ) {
        ( $id, $hash_id ) = $dbh->selectrow_array( qq[ SELECT id, hash_id FROM test_results WHERE progress=0 AND queue=? ORDER BY priority DESC, id ASC LIMIT 1 ], undef, $queue_label );
    }
    else {
        ( $id, $hash_id ) = $dbh->selectrow_array( q[ SELECT id, hash_id FROM test_results WHERE progress=0 ORDER BY priority DESC, id ASC LIMIT 1 ] );
    }

    if ($id) {
        $dbh->do( q[UPDATE test_results SET progress=1 WHERE id=?], undef, $id );
        $result_id = $hash_id;
    }
    return $result_id;
}

# Standatd SQL, can be here
sub get_batch_job_result {
    my ( $self, $batch_id ) = @_;

    my $dbh = $self->dbh;

    my %result;
    $result{nb_running} = 0;
    $result{nb_finished} = 0;

    my $query = "
        SELECT hash_id, progress
        FROM test_results
        WHERE batch_id=?";

    my $sth1 = $dbh->prepare( $query );
    $sth1->execute( $batch_id );
    while ( my $h = $sth1->fetchrow_hashref ) {
        if ( $h->{progress} eq '100' ) {
            $result{nb_finished}++;
            push(@{$result{finished_test_ids}}, $h->{hash_id});
        }
        else {
            $result{nb_running}++;
        }
    }

    return \%result;
}

sub process_unfinished_tests {
    my ( $self, $queue_label, $test_run_timeout, $test_run_max_retries ) = @_;

    my $sth1 = $self->select_unfinished_tests(    #
        $queue_label,
        $test_run_timeout,
        $test_run_max_retries,
    );

    while ( my $h = $sth1->fetchrow_hashref ) {
        if ( $h->{nb_retries} < $test_run_max_retries ) {
            $self->schedule_for_retry($h->{hash_id});
        }
        else {
            $self->force_end_test($h->{hash_id}, $test_run_timeout);
        }
    }
}

sub force_end_test {
    my ( $self, $hash_id, $timestamp ) = @_;

    $self->add_result_entry( $hash_id, {
        timestamp => $timestamp,
        module    => 'BACKEND_TEST_AGENT',
        testcase  => 'BACKEND',
        tag       => 'UNABLE_TO_FINISH_TEST',
        level     => 'CRITICAL',
        args      => {},
    });
    $self->test_progress($hash_id, 100);
}

sub process_dead_test {
    my ( $self, $hash_id, $test_run_max_retries ) = @_;
    my ( $nb_retries ) = $self->dbh->selectrow_array("SELECT nb_retries FROM test_results WHERE hash_id = ?", undef, $hash_id);
    if ( $nb_retries < $test_run_max_retries) {
        $self->schedule_for_retry($hash_id);
    } else {
        $self->force_end_test($hash_id, $self->get_relative_start_time($hash_id));
    }
}

# A thin wrapper around DBI->connect to ensure similar behavior across database
# engines.
sub _new_dbh {
    my ( $class, $data_source_name, $user, $password ) = @_;

    if ( $user ) {
        $log->noticef( "Connecting to database '%s' as user '%s'", $data_source_name, $user );
    }
    else {
        $log->noticef( "Connecting to database '%s'", $data_source_name );
    }

    my $dbh = DBI->connect(
        $data_source_name,
        $user,
        $password,
        {
            RaiseError => 1,
            AutoCommit => 1,
        }
    );

    $dbh->{AutoInactiveDestroy} = 1;

    return $dbh;
}

sub _project_params {
    my ( $self, $params ) = @_;

    my $profile = Zonemaster::Engine::Profile->effective;

    my %projection = ();

    $projection{domain}   = lc $$params{domain} // "";
    $projection{ipv4}     = $$params{ipv4}      // $profile->get( 'net.ipv4' );
    $projection{ipv6}     = $$params{ipv6}      // $profile->get( 'net.ipv6' );
    $projection{profile}  = $$params{profile}   // "default";

    my $array_ds_info = $$params{ds_info} // [];
    my @array_ds_info_sort = sort {
        $a->{algorithm} cmp $b->{algorithm} or
        $a->{digest}    cmp $b->{digest}    or
        $a->{digtype}   <=> $b->{digtype}   or
        $a->{keytag}    <=> $b->{keytag}
    } @$array_ds_info;

    $projection{ds_info} = \@array_ds_info_sort;

    my $array_nameservers = $$params{nameservers} // [];
    for my $nameserver (@$array_nameservers) {
        if ( defined $$nameserver{ip} and $$nameserver{ip} eq "" ) {
            delete $$nameserver{ip};
        }
        $$nameserver{ns} = lc $$nameserver{ns};
    }
    my @array_nameservers_sort = sort {
        $a->{ns} cmp $b->{ns} or
        ( defined $a->{ip} and defined $b->{ip} and $a->{ip} cmp $b->{ip} )
    } @$array_nameservers;

    $projection{nameservers} = \@array_nameservers_sort;

    return \%projection;
}

sub _params_to_json_str {
    my ( $self, $params ) = @_;

    my $js = JSON::PP->new;
    $js->canonical( 1 );

    my $encoded_params = $js->encode( $params );

    return $encoded_params;
}

=head2 encode_params

Encode the params object into a JSON string. First a projection of some
parameters is performed then all additional properties are kept.
Returns a JSON string of a the using a union of the given hash and its
normalization using default values, see
L<https://github.com/zonemaster/zonemaster-backend/blob/master/docs/API.md#params-2>

=cut

sub encode_params {
    my ( $self, $params ) = @_;

    my $projected_params = $self->_project_params( $params );
    $params = { %$params, %$projected_params };
    my $encoded_params = $self->_params_to_json_str( $params );

    return $encoded_params;
}

=head2 generate_fingerprint

Returns a fingerprint of the hash passed in argument.
The fingerprint is computed after projecting the hash.
Such fingerprint are usefull to find similar tests in the database.

=cut

sub generate_fingerprint {
    my ( $self, $params ) = @_;

    my $projected_params = $self->_project_params( $params );
    my $encoded_params = $self->_params_to_json_str( $projected_params );
    my $fingerprint = md5_hex( encode_utf8( $encoded_params ) );

    return $fingerprint;
}


=head2 undelegated

Returns the value 1 if the test to be created is if type undelegated,
else value 0. The test is considered to be undelegated if the "ds_info" or
"nameservers" parameters is are defined with data after projection.

=cut

sub undelegated {
    my ( $self, $params ) = @_;

    my $projected_params = $self->_project_params( $params );

    return 1 if defined( $$projected_params{ds_info}[0] );
    return 1 if defined( $$projected_params{nameservers}[0] );
    return 0;
}

sub add_result_entry {
    my ( $self, $hash_id, $entry ) = @_;

    my $json = JSON::PP->new->allow_blessed->convert_blessed->canonical;

    my $nb_inserted = $self->dbh->do(
        "INSERT INTO result_entries (hash_id, level, module, testcase, tag, timestamp, args) VALUES (?, ?, ?, ?, ?, ?, ?)",
        undef,
        $hash_id,
        $entry->{level},
        $entry->{module},
        $entry->{testcase},
        $entry->{tag},
        $entry->{timestamp},
        $json->encode( $entry->{args} ),
    );
    return $nb_inserted;
}

sub add_result_entries {
    my ( $self, $hash_id, $entries ) = @_;
    my @records;

    my $json = JSON::PP->new->allow_blessed->convert_blessed->canonical;

    foreach my $m ( @$entries ) {
        my $r = [
            $hash_id,
            $m->level,
            $m->module,
            $m->testcase,
            $m->tag,
            $m->timestamp,
            $json->encode( $m->args // {} ),
        ];

        push @records, $r;
    }
    my $query_values = join ", ", ("(?, ?, ?, ?, ?, ?, ?)") x @records;
    my $query = "INSERT INTO result_entries (hash_id, level, module, testcase, tag, timestamp, args) VALUES $query_values";
    my $sth = $self->dbh->prepare($query);
    $sth = $sth->execute(map { @$_ } @records);
}

no Moose::Role;

1;
