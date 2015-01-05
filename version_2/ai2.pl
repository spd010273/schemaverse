#!/usr/bin/perl

$|=1;

use strict;
use warnings;

use DBI;
use Validate_lib;
use Getopt::Std;
use Data::Dumper;

our( $opt_u, $opt_p );

die( "Bad arguments\n" ) unless( getopts( 'u:p:' ) );

my $username = $opt_u;
my $password = $opt_p;

die( "No -u username" ) unless( $username );
die( "No -p password" ) unless( $password );
use constant DEBUG              => 1;

use constant WAIT_TIME          => 10;

# Game constants - these can alter the outcome of a game
use constant CAPITAL_NUMBER     => 3; # Number of capital ships in a fleet
use constant CAPITAL_PER_PLANET => 1;
use constant DEFENSE_PERCENT    => 0.1; # Percentage of mine_limit ( per planet defensive population )
use constant HEALER_NUMBER      => 1;

use constant LDBASE_HOSTNAME     => 'localhost';
use constant LDBASE_PORT         => '5432';
use constant LDBASE_TYPE         => 'Pg';
use constant LDBASE_SID          => 'schemaverse';
use constant LDBASE_USERNAME     => $username;
use constant LDBASE_PASSWORD     => $password;
use constant LDBASE_CONNECT_PERL => 'dbi:'. LDBASE_TYPE .':dbname='.LDBASE_SID.';host='.LDBASE_HOSTNAME.';port='.LDBASE_PORT;

use constant SHIP_START_POINTS  => 20;

use constant SHIP_ROLE_MINER    => 1;
use constant SHIP_ROLE_DEFENSE  => 2;
use constant SHIP_ROLE_CAPITAL  => 3;
use constant SHIP_ROLE_HEALER   => 4;

use constant MINE_BASE_FUEL     => 'MINE_BASE_FUEL';     # This value is used as a multiplier for fuel discovered from all planets
use constant EXPLODED           => 'EXPLODED';           # After this many tics, a ship will explode. Cost of a base ship will be returned to the player
use constant MAX_SHIPS          => 'MAX_SHIPS';          # The max number of ships a player can control at any time. Destroyed ships do not count.
use constant MAX_SHIP_SKILL     => 'MAX_SHIP_SKILL';     # This is the total amount of shill a ship can have ( attack + defense + engineering + prospecting )
use constant MAX_SHIP_RANGE     => 'MAX_SHIP_RANGE';     # This is the maximum range a ship can have
use constant MAX_SHIP_FUEL      => 'MAX_SHIP_FUEL';      # This is the maximum fuel a ship can have
use constant MAX_SHIP_SPEED     => 'MAX_SHIP_SPEED';     # This is the maximum speed a ship can travel
use constant MAX_SHIP_HEALTH    => 'MAX_SHIP_HEALTH';    # This is the maximum health a ship can have
use constant ROUND_LENGTH       => 'ROUND_LENGTH';       # The length of time a round takes to complete
use constant DEFENSE_EFFICIENCY => 'DEFENCE_EFFICIENCY'; # Used to calculate attack with defense
use constant ROUND_START_DATE   => 'ROUND_START_DATE';   # The day the round started

use constant PRICE_SHIP         => 'SHIP';
use constant FLEET_RUNTIME      => 'FLEET_RUNTIME';
use constant MAX_HEALTH         => 'MAX_HEALTH';
use constant MAX_FUEL           => 'MAX_FUEL';
use constant MAX_SPEED          => 'MAX_SPEED';
use constant RANGE              => 'RANGE';
use constant ATTACK             => 'ATTACK';
use constant DEFENSE            => 'DEFENSE';
use constant ENGINEERING        => 'ENGINEERING';
use constant PROSPECTING        => 'PROSPECTING';

#my $rhandle = DBI->connect( RDBASE_CONNECT_PERL, RDBASE_USERNAME, RDBASE_PASSWORD, { AutoCommit => 1, ShowErrorStatement => 1 } );

# ====== Globals
my $role        = [ SHIP_ROLE_MINER, SHIP_ROLE_DEFENSE, SHIP_ROLE_CAPITAL, SHIP_ROLE_HEALER ];
my $ship        = { }; # {
                       #   ship_id  => {
                       #                    stats           => { 
                       #                                           attack => val,
                       #                                           defense => val,
                       #                                           engineering => val,
                       #                                           prospecting => val
                       #                                       },
                       #                    role            => ROLE_CONSTANT,
                       #                    planet          => planet_id,
                       #                    fleet           => fleet_id,
                       #                    position_x      => val,
                       #                    position_y      => val,
                       #                    speed           => val,
                       #                    direction       => val,
                       #                    destination_x   => val,
                       #                    destination_y   => val,
                       #               },
                       #   ...
                       # }
my $fleet       = { }; # { fleet_id => { ship_id => is_alive} }
my $fleet_by_role = { }; # { role => { $fleet_id => [ ship_id ] }
my $planet      = { }; # { 
                       #   planet_id => {
                       #                    name        => planet_name,
                       #                    position_x  => val,
                       #                    position_y  => val,
                       #                    mine_limit  => val
                       #                },
                       #   ...
                       # }
my $public_variable = { };
my $ships_by_role = { };
my $ships_actioned = [ ];
my $capitals_in_flight = { }; # { fleet_id => destination }
my $price_list  = { };

my $population  = 0;
my $player_name = 'spd010273';
my $player_id   = 0;
my $balance     = 0;
my $fuel        = 0;
my $current_tic = 0;
my $last_tic    = 0;
my $ship_count_limit = 2000;
my $ship_count  = 0;
my $tic_stats   = {
                    'ships_needed'  => {
                                            1 => 1,
                                            2 => 1,
                                            3 => 1,
                                            4 => 1
                                       },
                    'upgrades_needed' => {
                                            1 => 1,
                                            2 => 1,
                                            3 => 1,
                                            4 => 1
                                         }
                  };

# Hash for each ship role, what stats get what percentage of MAX_SHIP_SKILL
my $ship_design_spec    = { };
   $ship_design_spec->{1}->{PROSPECTING} = 1;
   $ship_design_spec->{2}->{ATTACK     } = 0.8;
   $ship_design_spec->{2}->{DEFENSE    } = 0.1;
   $ship_design_spec->{2}->{ENGINEERING} = 0.1;
   $ship_design_spec->{3}->{ATTACK     } = 0.608;
   $ship_design_spec->{3}->{DEFENSE    } = 0.2;
   $ship_design_spec->{3}->{ENGINEERING} = 0.1;
   $ship_design_spec->{3}->{PROSPECTING} = 0.002; # Necessary - capital ships must be able to mine
   $ship_design_spec->{4}->{ENGINEERING} = 0.9;
   $ship_design_spec->{4}->{DEFENSE    } = 0.1;

sub initialize($)
{
    my( $handle ) = @_;
    my $function_create_q = <<SQL;
CREATE OR REPLACE FUNCTION pg_temp.new_ship
(
    in_planet       INTEGER,
    in_role         INTEGER,
    in_attack       INTEGER,
    in_defense      INTEGER,
    in_prospecting  INTEGER,
    in_engineering  INTEGER,
    in_fleet        INTEGER DEFAULT NULL
)
RETURNS TABLE
(
    ship_id         INTEGER,
    fleet_id        INTEGER
)
AS
 \$function\$
DECLARE
    my_fleet        INTEGER;
    my_ship_name    VARCHAR;
BEGIN
    IF( in_fleet IS NULL ) THEN
        INSERT INTO my_fleets
                    (
                        name
                    )
             SELECT p.id
                 || (
                    CASE WHEN in_role = 1 THEN '_miner'::VARCHAR
                         WHEN in_role = 2 THEN '_defense'::VARCHAR
                         WHEN in_role = 3 THEN '_capital'::VARCHAR
                         WHEN in_role = 4 THEN '_healer'::VARCHAR
                         ELSE '_wut'::VARCHAR
                          END
                    ) AS name
               FROM planets p
              WHERE p.id = in_planet;

        SELECT f.id
          INTO my_fleet
          FROM my_fleets f
    INNER JOIN planets p
            ON f.name = p.id
                     || (
                            CASE WHEN in_role = 1 THEN '_miner'::VARCHAR
                                 WHEN in_role = 2 THEN '_defense'::VARCHAR
                                 WHEN in_role = 3 THEN '_capital'::VARCHAR
                                 WHEN in_role = 4 THEN '_healer'::VARCHAR
                                 ELSE '_wut'::VARCHAR
                                  END
                        )
           AND p.id = in_planet;
    ELSE
        my_fleet := in_fleet;
    END IF;
     
    SELECT f.id::VARCHAR || '-' || ( COUNT(s.*) + 1 )::VARCHAR || '-' || in_role::VARCHAR AS name
      INTO my_ship_name
      FROM my_fleets f
 LEFT JOIN my_ships s
        ON s.fleet_id = f.id
INNER JOIN planets p
        ON p.id = in_planet
     WHERE f.id = my_fleet
  GROUP BY f.id;

    RAISE NOTICE 'name %, attack %, defense, %, pros, %, engi %, fleet %, loc %', my_ship_name, in_attack, in_defense, in_prospecting, in_engineering, my_fleet, in_planet;
    INSERT INTO my_ships
                (
                    name,
                    attack,
                    defense,
                    prospecting,
                    engineering,
                    fleet_id,
                    location
                )
         SELECT my_ship_name AS name,
                in_attack AS attack,
                in_defense AS defense,
                in_prospecting AS prospecting,
                in_engineering AS engineering,
                my_fleet AS fleet_id,
                p.location
           FROM planets p
          WHERE p.id = in_planet;

    RETURN QUERY
    SELECT s.id AS ship_id,
           s.fleet_id
      FROM my_ships s
     WHERE s.name = my_ship_name;
END
 \$function\$
    LANGUAGE 'plpgsql';
SQL
    $handle->do( $function_create_q ) or warn( 'Failed to create pg_temp.new_ship' );
    
    $function_create_q = <<SQL;
CREATE OR REPLACE FUNCTION pg_temp.repair_handler
(
    in_needs_repair         INTEGER,
    in_repair_candidates    INTEGER[]
)
RETURNS INTEGER[] AS
 \$_\$
DECLARE
    my_repairers            INTEGER[];
    my_repairer             RECORD;
    my_needed_health        INTEGER;
BEGIN
    SELECT s.max_health - s.current_health AS needed_health
      INTO my_needed_health
      FROM my_ships s
     WHERE s.id = in_needs_repair;
     
    FOR my_repairer IN( 
                            SELECT s.id,
                                   s.engineering
                              FROM my_ships s
                              JOIN ( SELECT unnest( in_repair_candidates ) AS id ) x
                                ON s.id = x.id
                          ORDER BY s.engineering DESC
                      ) LOOP
        IF( my_repairer.engineering <= my_needed_health ) THEN
            my_repairers     := array_append( my_repairers, my_repairer.id );
            my_needed_health := my_needed_health - my_repairer.engineering;
        END IF;
    END LOOP;

    RETURN my_repairers;
END
 \$_\$
    LANGUAGE 'plpgsql' STABLE;
SQL

    $handle->do( $function_create_q ) or warn( 'Failed to create pg_temp.repair_handler' );

    $function_create_q = <<SQL;
CREATE OR REPLACE FUNCTION pg_temp.get_center
(
    in_points POINT[]
)
RETURNS POINT AS
 \$function\$
DECLARE
    my_point    POINT;
    my_count    INTEGER;
    my_x_sum    INTEGER;
    my_y_sum    INTEGER;
BEGIN
    my_x_sum := 0;
    my_y_sum := 0;
    my_count := 0;
    
    FOR my_point IN( SELECT unnest( in_points ) ) LOOP
        my_x_sum := my_x_sum + my_point[0];
        my_y_sum := my_y_sum + my_point[0];
        my_count := my_count + 1;
    END LOOP;

    my_point := ( '(' || ( my_x_sum::FLOAT / my_count )::VARCHAR || ',' || ( my_y_sum::FLOAT / my_count )::VARCHAR || ')'  )::POINT;
    RETURN my_point;
END
 \$function\$
   LANGUAGE 'plpgsql' IMMUTABLE;
SQL

    $handle->do( $function_create_q );
    
    return;
}

sub state_sync($)
{
    my( $handle ) = @_;
    # Synchronizes the state of the game on the server with the local
    my $query;
    my $sth;
    
    print "Refreshing state...\n" if( DEBUG );
    if( $last_tic == 0 )
    {
        $public_variable    = { };
        $ships_by_role      = { };
        $ships_actioned     = [ ];
        $capitals_in_flight = { }; # { fleet_id => destination }
        $price_list         = { };
        $fleet              = { };
        $planet             = { };
        $fleet_by_role      = { };
        $ship               = { };
        $population         = 0;
        $ship_count         = 0;
        $tic_stats          = {
                                'ships_needed'  => {
                                                        1 => 1,
                                                        2 => 1,
                                                        3 => 1,
                                                        4 => 1
                                                   },
                                'upgrades_needed' => {
                                                        1 => 1,
                                                        2 => 1,
                                                        3 => 1,
                                                        4 => 1
                                                     }
                              };
        # Price list    
        $query = <<SQL;
        SELECT code,
               cost
          FROM price_list;
SQL
           $sth = $handle->prepare( $query );
           $sth->execute() or warn( 'Failed to execute query' );

        while( my $row = $sth->fetchrow_hashref() )
        {
            $price_list->{$row->{'code'}} = $row->{'cost'};
        }

        # Variables
        $query = <<SQL;
       SELECT name,
              numeric_value
         FROM public_variable
        WHERE numeric_value IS NOT NULL
SQL
        $sth = $handle->prepare( $query );
        $sth->execute() or warn( 'Failed to execute query' );

        while( my $row = $sth->fetchrow_hashref() )
        {
            $public_variable->{$row->{'name'}} = $row->{'numeric_value'};
        }
    }

        $query = <<SQL;
    SELECT last_value AS current_tic,
           CASE WHEN last_value = ?::INTEGER
                THEN FALSE
                ELSE TRUE
                 END AS is_new_tic,
           ?::INTEGER AS last_tic
      FROM tic_seq
SQL
    
       $sth = $handle->prepare( $query );
       $sth->bind_param( 1, $last_tic );
       $sth->bind_param( 2, $last_tic );
       $sth->execute() or warn( 'Failed to syncronize tic_seq' );
    my $row = $sth->fetchrow_hashref();
    
    $last_tic      = $row->{'last_tic'   }; 
    $current_tic   = $row->{'current_tic'}; 
    my $is_new_tic = $row->{'is_new_tic' };
    $last_tic      = $current_tic if( $is_new_tic ); 
    return $is_new_tic unless( $is_new_tic );

    # A new tic has occurred, lets sync the rest of our game data with local hashes
       $query = <<SQL;
    SELECT id,
           balance,
           fuel_reserve
      FROM my_player;
SQL
       $sth = $handle->prepare( $query );
       $sth->execute() or warn( 'Failed to synchronize my_player' );
       $row = $sth->fetchrow_hashref();
    
    $player_id  = $row->{'id'};
    $balance    = $row->{'balance'};
    $fuel       = $row->{'fuel_reserve'};

       $query =<<SQL;   
    SELECT id,
           name,
           location_x AS position_x,
           location_y AS potition_y,
           mine_limit
      FROM planets
     WHERE conqueror_id = ?
SQL
        $sth = $handle->prepare( $query );
        $sth->bind_param( 1, $player_id );
        $sth->execute() or warn( 'Failed to synchronize planets' );

    while( my $row = $sth->fetchrow_hashref() )
    {
        $planet->{$row->{'id'}} = {
                                      'name'        => $row->{'name'},
                                      'position_x'  => $row->{'position_x'},
                                      'position_y'  => $row->{'position_y'},
                                      'mine_limit'  => $row->{'mine_limit'}
                                   };
    }
       
       $query = <<SQL;
    SELECT s.id,
           s.name,
           s.direction,
           s.speed,
           s.destination_x,
           s.destination_y,
           s.attack,
           s.defense,
           s.engineering,
           s.prospecting,
           s.current_health,
           s.current_fuel,
           s.fleet_id,
           s.location_x AS position_x,
           s.location_y AS position_y,
           p.id AS planet,
           CASE WHEN s.current_health > 0
                THEN TRUE
                ELSE FALSE
                 END AS is_alive,
           CASE WHEN p.conqueror_id = ?
                THEN TRUE
                ELSE FALSE
                 END AS is_my_planet
      FROM my_ships s
 LEFT JOIN planets p
        ON circle( p.location, s.range ) @> s.location;
SQL
    if( $last_tic == 0 )
    {
           $sth = $handle->prepare( $query );
           $sth->bind_param( 1, $player_id );
           $sth->execute() or warn( 'Failed to synchronize ships' );

        while( my $row = $sth->fetchrow_hashref() )
        {
            $ship->{$row->{'id'}} = {
                                        'direction' => $row->{'direction'},
                                        'speed'     => $row->{'speed'},
                                        'stats'     => {
                                                        'attack'        => $row->{'attack'},
                                                        'defense'       => $row->{'defense'},
                                                        'prospecting'   => $row->{'prospecting'},
                                                        'engineering'   => $row->{'engineering'}
                                                       },
                                        'fleet'     => $row->{'fleet_id'},
                                        'name'      => $row->{'name'},
                                        'planet'    => $row->{'planet'},
                                        'destination_x' => $row->{'destination_x'},
                                        'destination_y' => $row->{'destination_y'},
                                        'position_x'    => $row->{'position_x'},
                                        'position_y'    => $row->{'position_y'},
                                    };

            $fleet->{$row->{'fleet_id'}}->{$row->{'id'}} = $row->{'is_alive'};
        }
    }
       $query = <<SQL;
WITH tt_capital_fleets AS
(
    SELECT f.id AS fleet_id
      FROM my_fleets f
     WHERE f.name LIKE '%_capital'
)
    SELECT DISTINCT ON( tt.fleet_id )
           tt.fleet_id,
           p.id AS planet_id
      FROM tt_capital_fleets tt
INNER JOIN my_ships s
        ON s.fleet_id = tt.fleet_id
INNER JOIN planets p
        ON CIRCLE( p.location, 1000 ) @> s.destination
SQL
    
       $sth = $handle->prepare( $query );
       $sth->execute() or warn( 'Failed to get fleets in flight' );
    
    while( my $row = $sth->fetchrow_hashref() )
    {
        $capitals_in_flight->{$row->{'fleet_id'}} = $row->{'planet_id'};
    }

       $query = <<SQL;
   SELECT ship_id_1 AS ship_id
     FROM my_events
    WHERE tic = ?
SQL
        $sth = $handle->prepare( $query );
        $sth->bind_param( 1, $current_tic );
        $sth->execute() or warn( 'Failed to get last ship actions' );
    
    $ships_actioned = [ ];

    while( my $row = $sth->fetchrow_hashref() )
    {
        push( @$ships_actioned, $row->{'ship_id'} );
    }

        $query = <<SQL;
    SELECT COUNT( id ) AS ship_count
      FROM my_ships
     WHERE current_health > 0
SQL
        $sth = $handle->prepare( $query );
        $sth->execute() or warn( 'Failed to get ship count' );
        $row = $sth->fetchrow_hashref();
  
    $ship_count = $row->{'ship_count'};
    
    return $is_new_tic; 
}

sub create_ship($$$;$)
{
    my( $handle, $planet_id, $role, $fleet_id ) = @_;
    return if( $ship_count >= $ship_count_limit ); 
    $fleet_id = ( $fleet_id ? $fleet_id : undef );

    my $spec_hash = $ship_design_spec->{$role};
    return unless( $spec_hash );
    my $ship_price_code = PRICE_SHIP;
    
    unless( $balance >= $price_list->{$ship_price_code} )
    {
        print "Not enough money to create ship\n" if( DEBUG );
        return;
    }
   
    my $attack      = int( SHIP_START_POINTS * ( $spec_hash->{ATTACK     } ? $spec_hash->{ATTACK     } : 0 ) );
    my $defense     = int( SHIP_START_POINTS * ( $spec_hash->{DEFENSE    } ? $spec_hash->{DEFENSE    } : 0 ) );
    my $prospecting = int( SHIP_START_POINTS * ( $spec_hash->{PROSPECTING} ? $spec_hash->{PROSPECTING} : 0 ) );
    my $engineering = int( SHIP_START_POINTS * ( $spec_hash->{ENGINEERING} ? $spec_hash->{ENGINEERING} : 0 ) );
    
    my $query = <<SQL;
    SELECT *
      FROM pg_temp.new_ship
           (
               ?,
               ?,
               ?,
               ?,
               ?,
               ?,
               ?
           )
SQL
 
    my $sth = $handle->prepare( $query );
    my $delta = $attack + $defense + $prospecting;
    if( SHIP_START_POINTS > ( $delta + $engineering ) )
    {
    #    $engineering = $engineering + ( SHIP_START_POINTS - $delta );
    }

       $sth->bind_param( 1, $planet_id   );
       $sth->bind_param( 2, $role        );
       $sth->bind_param( 3, $attack      );
       $sth->bind_param( 4, $defense     );
       $sth->bind_param( 5, $prospecting );
       $sth->bind_param( 6, $engineering );
       $sth->bind_param( 7, $fleet_id    );
       $sth->execute() or warn( 'Failed to create ship' );
    my $row = $sth->fetchrow_hashref();
       $fleet_id = $row->{'fleet_id'};
    my $ship_id  = $row->{'ship_id' };
    
    if( $ship_id )
    {
        print "Getting data for newly created ship\n" if( DEBUG );
        $query = <<SQL;
    SELECT s.id,
           s.name,
           s.direction,
           s.speed,
           s.destination_x,
           s.destination_y,
           s.attack,
           s.defense,
           s.engineering,
           s.prospecting,
           s.current_health,
           s.current_fuel,
           s.fleet_id,
           s.location_x AS position_x,
           s.location_y AS position_y
      FROM my_ships s
     WHERE s.id = ?
SQL

        $sth = $handle->prepare( $query );
        $sth->bind_param( 1, $ship_id );
        $sth->execute() or warn( 'Failed to get newly created ship' );
        $row = $sth->fetchrow_hashref();
        push( @{$ships_by_role->{$role}}, $row->{'id'} );
        
        $ship->{$row->{'id'}} = {
                                    'direction' => $row->{'direction'},
                                    'speed'     => $row->{'speed'},
                                    'stats'     => {
                                                    'attack'        => $row->{'attack'},
                                                    'defense'       => $row->{'defense'},
                                                    'prospecting'   => $row->{'prospecting'},
                                                    'engineering'   => $row->{'engineering'}
                                                   },
                                    'fleet'     => $fleet_id,
                                    'planet'    => $planet_id,
                                    'role'      => $role,
                                    'name'      => $row->{'name'},
                                    'destination_x' => $row->{'destination_x'},
                                    'destination_y' => $row->{'destination_y'},
                                    'position_x'    => $row->{'position_x'},
                                    'position_y'    => $row->{'position_y'},
                                };
        $fleet->{$fleet_id}->{$row->{'id'}} = 1;
        $balance = $balance - $price_list->{$ship_price_code}; 
        push( @{$fleet_by_role->{$fleet_id}}, $ship_id );
        print "Ship id " . $row->{'id'} . " name " . $row->{'name'} . " created\n" if( DEBUG );
        $ship_count++; 
        return $row->{'id'};
    }
    
    return;
}

sub build_healer($)
{
    my( $handle ) = @_;
    return if( $ship_count >= $ship_count_limit ); 
    my $healer_count = HEALER_NUMBER;

    my $query = <<SQL;
    SELECT p.id,
           ?::INTEGER AS ships_to_build,
           NULL AS fleet_id
      FROM planets p
 LEFT JOIN my_fleets f
        ON f.name LIKE '%_healer'
       AND regexp_replace( f.name, '_.*\$', '' )::INTEGER = p.id
     WHERE p.conqueror_id = ?
       AND f.id IS NULL
     UNION
    SELECT p.id,
           ?::INTEGER - COUNT( s.* ) AS ships_to_build,
           f.id AS fleet_id
      FROM planets p
INNER JOIN my_fleets f
        ON f.name LIKE '%_healer'
       AND regexp_replace( f.name, '_.*\$', '' )::INTEGER = p.id
INNER JOIN my_ships s
        ON s.fleet_id = f.id
     WHERE p.conqueror_id = ?
  GROUP BY p.id,
           f.id
SQL
    
    my $sth = $handle->prepare( $query );
       $sth->bind_param( 1, $healer_count );
       $sth->bind_param( 2, $player_id );
       $sth->bind_param( 3, $healer_count );
       $sth->bind_param( 4, $player_id );
       $sth->execute() or warn( 'Could not determine the number of healer ships to build' );
    $tic_stats->{'ships_needed'}->{4} = 0 if( $sth->rows() == 0 );
    
    while( my $row = $sth->fetchrow_hashref() )
    {
        my $planet_id = $row->{'id'            };
        my $count     = $row->{'ships_to_build'};
        my $fleet_id  = $row->{'fleet_id'      };
        
        for( my $i = 0; $i < $count; $i++ )
        {
            my $ship_id  = &create_ship( $handle, $planet_id, SHIP_ROLE_HEALER, $fleet_id );
            last unless( $ship_id );
            $fleet_id = $ship->{$ship_id}->{'fleet'};
            warn 'No fleet returned by create_ship!' unless( $fleet_id );
            $tic_stats->{'upgrades_needed'}->{4} = 1 if( $fleet_id );
        }
    }

    return 0;
}

sub build_defense($)
{
    my( $handle ) = @_;
    return if( $ship_count >= $ship_count_limit ); 
    my $defense_percent = DEFENSE_PERCENT;
    my $query = <<SQL;
    WITH tt_defense_to_build AS
    (
        SELECT p.id,
               p.mine_limit,
               COUNT( s.* ) AS ship_count,
               array_to_string( array_agg( distinct regexp_replace( s.name, '-.*\$', '' ) ), ',' ) AS fleet_id
          FROM planets p
     LEFT JOIN my_ships s
            ON CIRCLE( s.location, s.range ) @> p.location
           AND s.name LIKE '%-2'
         WHERE p.conqueror_id = ?
      GROUP BY p.id,
               p.mine_limit
    )
        SELECT tt.id,
               tt.fleet_id,
               ceil( ( tt.mine_limit * ?::FLOAT )::FLOAT - tt.ship_count ) AS ships_to_build
          FROM tt_defense_to_build tt
         WHERE ceil( ( tt.mine_limit * ?::FLOAT )::FLOAT - tt.ship_count ) > 0
SQL
    my $sth = $handle->prepare( $query );
       $sth->bind_param( 1, $player_id );
       $sth->bind_param( 2, $defense_percent );
       $sth->bind_param( 3, $defense_percent );
       $sth->execute() or warn( 'Could not determine the number of defense ships to build' );
    $tic_stats->{'ships_needed'}->{2} = 0 if( $sth->rows() == 0 );
    while( my $row = $sth->fetchrow_hashref() )
    {
        my $planet_id = $row->{'id'            };
        my $count     = $row->{'ships_to_build'};
        my $fleet_id  = $row->{'fleet_id'      };
        
        for( my $i = 0; $i < $count; $i++ )
        {
            my $ship_id  = &create_ship( $handle, $planet_id, SHIP_ROLE_DEFENSE, $fleet_id );
            last unless( $ship_id );
            $fleet_id = $ship->{$ship_id}->{'fleet'};
            warn 'No fleet returned by create_ship!' unless( $fleet_id );
            $tic_stats->{'upgrades_needed'}->{2} = 1 if( $fleet_id );
        }
    }
    
    return;
}

sub build_capital($)
{
    my( $handle ) = @_;
    return if( $ship_count >= $ship_count_limit ); 
    my $capital_count_per_fleet = CAPITAL_NUMBER;
    my $query = <<SQL;
    SELECT p.id,
           ?::INTEGER AS ships_to_build,
           NULL AS fleet_id
      FROM planets p
 LEFT JOIN my_fleets f
        ON f.name LIKE '%_capital'
       AND regexp_replace( f.name, '_.*\$', '' )::INTEGER = p.id
     WHERE p.conqueror_id = ?
       AND f.id IS NULL
     UNION
    SELECT p.id,
           ?::INTEGER - COUNT( s.id ) AS ships_to_build,
           f.id AS fleet_id
      FROM planets p
INNER JOIN my_fleets f
        ON f.name LIKE '%_capital'
       AND regexp_replace( f.name, '_.*\$', '' )::INTEGER = p.id
 LEFT JOIN my_ships s
        ON s.fleet_id = f.id
     WHERE p.conqueror_id = ?
  GROUP BY p.id,
           f.id
    HAVING COUNT( s.id ) < ?
SQL
    
    my $sth = $handle->prepare( $query );
       $sth->bind_param( 1, $capital_count_per_fleet );
       $sth->bind_param( 2, $player_id               );
       $sth->bind_param( 3, $capital_count_per_fleet );
       $sth->bind_param( 4, $player_id               );
       $sth->bind_param( 5, $capital_count_per_fleet );
       $sth->execute() or warn( 'Could not determine the number of capital ships to build' );
    $tic_stats->{'shipes_needed'}->{3} = 0 if( $sth->rows() == 0 );

    while( my $row = $sth->fetchrow_hashref() )
    {
        my $planet_id = $row->{'id'            };
        my $count     = $row->{'ships_to_build'};
        my $fleet_id  = $row->{'fleet_id'      };
        
        for( my $i = 0; $i < $count; $i++ )
        {
            my $ship_id  = &create_ship( $handle, $planet_id, SHIP_ROLE_CAPITAL, $fleet_id );
            print "Invalid ship_id!\n" unless( $ship_id );
            last unless( $ship_id );
            $fleet_id = $ship->{$ship_id}->{'fleet'};
            warn 'No fleet returned by create_ship!' unless( $fleet_id );
            $tic_stats->{'upgrades_needed'}->{3} = 1 if( $fleet_id );
        }
    }

    return;
}

sub build_miners($)
{
    my( $handle ) = @_;
    return if( $ship_count >= $ship_count_limit ); 
    my $query = <<SQL;
    WITH tt_miners_to_build AS
    (
        SELECT p.id,
               p.mine_limit,
               COUNT( s.* ) AS ship_count,
               array_to_string( array_agg( distinct regexp_replace( s.name, '-.*\$', '' ) ), ',' ) AS fleet_id
          FROM planets p
     LEFT JOIN my_ships s
            ON CIRCLE( s.location, s.range ) @> p.location
           AND s.name LIKE '%-1'
         WHERE p.conqueror_id = ?
      GROUP BY p.id,
               p.mine_limit
    ) 
        SELECT tt.id,
               tt.fleet_id,
               tt.mine_limit - tt.ship_count AS ships_to_build
          FROM tt_miners_to_build tt
         WHERE ( tt.mine_limit - tt.ship_count ) > 0
SQL
    
    my $sth = $handle->prepare( $query );
       $sth->bind_param( 1, $player_id );
       $sth->execute() or warn( 'Could not determine the number of miners to build' );
    $tic_stats->{'ships_needed'}->{1} = 0 if( $sth->rows() == 0 );

    while( my $row = $sth->fetchrow_hashref() )
    {
        my $planet_id = $row->{'id'            };
        my $count     = $row->{'ships_to_build'};
        my $fleet_id  = $row->{'fleet_id'      };
        
        for( my $i = 0; $i < $count; $i++ )
        {
            my $ship_id  = &create_ship( $handle, $planet_id, SHIP_ROLE_MINER, $fleet_id );
            last unless( $ship_id );
            $fleet_id = $ship->{$ship_id}->{'fleet'};
            warn 'No fleet returned by create_ship!' unless( $fleet_id );
            $tic_stats->{'upgrades_needed'}->{1} = 1 if( $fleet_id );
        }
    }

    return;
}
sub manage_balance_conversion($)
{
    my( $handle ) = @_;
    my $query = <<SQL;
    WITH tt_capital_ships AS
    (
        SELECT f.id
          FROM my_fleets f
         WHERE f.name LIKE '%_capital'
    ),
    tt_fuel_needed AS
    (
        SELECT s.id,
               s.max_speed - s.speed AS accel_need,
               s.max_fuel - s.max_fuel AS fuel_tank
          FROM my_ships s
    INNER JOIN tt_capital_ships c
            ON c.id = s.fleet_id
    )
        SELECT COALESCE( SUM( accel_need ) + SUM( fuel_tank ), 0 ) AS fuel_reserve
          FROM tt_fuel_needed
SQL
    my $sth = $handle->prepare( $query );
       $sth->execute() or warn( 'Couldnt determine fuel reserve to keep' );
    my $row = $sth->fetchrow_hashref();
    my $fuel_reserve = $row->{'fuel_reserve'};

    my $desired_fuel = $fuel;
       $desired_fuel = $desired_fuel * -2 if( $desired_fuel < 0 );
       $desired_fuel = $fuel_reserve if( $fuel_reserve > $fuel );
    
    # are we running a fuel defecit?
    my $to_convert = 0;
       $to_convert = abs( $desired_fuel ) if( abs($desired_fuel) < $balance );
       $to_convert = $balance if( abs( $desired_fuel ) > $balance );
       $query = <<SQL;
    SELECT CONVERT_RESOURCE( 'MONEY', ? ) AS converted
SQL
       $sth = $handle->prepare( $query );
       $sth->bind_param( 1, $to_convert );
       $sth->execute() or warn( 'Failed to exchange money for fuel' );
       $row = $sth->fetchrow_hashref();
    my $ammount_converted = $row->{'converted'};
    
    $balance = $balance - $ammount_converted if( $ammount_converted );
    $fuel = $fuel + $ammount_converted if( $ammount_converted );
    return;
}

sub manage_fuel_conversion($)
{
    my( $handle ) = @_;
    
    # Every tic, we'll have just enough fuel to accel/decel every capital ship, plus refueling
    my $query = <<SQL;
    WITH tt_capital_ships AS
    (
        SELECT f.id
          FROM my_fleets f
         WHERE f.name LIKE '%_capital'
    ),
    tt_fuel_needed AS
    (
        SELECT s.id,
               s.max_speed - s.speed AS accel_need,
               s.max_fuel - s.max_fuel AS fuel_tank
          FROM my_ships s
    INNER JOIN tt_capital_ships c
            ON c.id = s.fleet_id
    )
        SELECT COALESCE( SUM( accel_need ) + SUM( fuel_tank ), 0 ) AS fuel_reserve
          FROM tt_fuel_needed
SQL
    my $sth = $handle->prepare( $query );
       $sth->execute() or warn( 'Couldnt determine fuel reserve to keep' );
    my $row = $sth->fetchrow_hashref();

    my $fuel_reserve = $row->{'fuel_reserve'};
    print "keeping $fuel_reserve fuel in reserve\n";

    my $conversion_q = <<SQL;
    SELECT CONVERT_RESOURCE( 'FUEL', fuel_reserve - ? ) AS conversion,
           fuel_reserve - ? AS balance_update
      FROM my_player;
SQL
    my $conversion_sth = $handle->prepare( $conversion_q );
       $conversion_sth->bind_param( 1, $fuel_reserve );
       $conversion_sth->bind_param( 2, $fuel_reserve );
       $conversion_sth->execute() or warn( 'Failed to convery fuel' );

    # Note: conversion may not by 1:1 TODO: Account for this with a constant
    my $conversion_row = $conversion_sth->fetchrow_hashref();
       $balance       += $conversion_row->{'balance_update'};
       $fuel          -= $fuel_reserve;
    print "Working balance: $balance fuel: $fuel\n" if( DEBUG );
    return;
}

sub repair_ships($)
{
    my( $handle ) = @_;
    my $actioned_ship_string = join( ',', @$ships_actioned );
    my $query = <<SQL;
    WITH tt_ships_needing_repair AS
    (
        SELECT s.id
          FROM my_ships s
         WHERE s.current_health < s.max_health
    ),
    tt_repair AS
    (
        SELECT DISTINCT ON( r.id )
               s.id AS need_repair,
               s.max_health - s.current_health AS health_needed,
               r.id AS repair,
               r.engineering
          FROM my_ships r
    INNER JOIN my_ships s
            ON CIRCLE( r.location, r.range ) @> s.location
    INNER JOIN tt_ships_needing_repair tt
            ON tt.id = s.id
         WHERE r.engineering > 0
           AND r.current_health > 0
SQL
    $query .= " AND r.id NOT IN( $actioned_ship_string )" if( scalar( @$ships_actioned ) > 0 );
    $query .= <<SQL;
    ),
    tt_repair_handler AS
    (
        SELECT pg_temp.repair_handler( need_repair, array_agg( repair ) ) AS repairers, need_repair
          FROM tt_repair
      GROUP BY need_repair
    )
        SELECT unnest( repairers ) AS repairer,
               need_repair
          FROM tt_repair_handler
SQL

    my $sth = $handle->prepare( $query );
       $sth->execute() or warn( 'Failed to get list of ships needing repair' );
    
    return if( $sth->rows() == 0 );
    
    while( my $row = $sth->fetchrow_hashref() )
    {
        my $repair_q = <<SQL;
        SELECT REPAIR( ?, ? ) AS repaired
SQL
        my $repair_sth = $handle->prepare( $repair_q );
           $repair_sth->bind_param( 1, $row->{'repairer'} );
           $repair_sth->bind_param( 2, $row->{'need_repair'} );
           $repair_sth->execute() or warn( 'Failed to run repair command' );

        my $repair_row = $repair_sth->fetchrow_hashref();
        if( $repair_row->{'repaired'} )
        {
            print $row->{'repairer'} . ' repaired ' . $row->{'need_repair'} . "\n";
            push( @$ships_actioned, $row->{'repairer'} );
        }
    }

    return;
}

sub refuel_ships($)
{
    my( $handle ) = @_;
    # Refueling does not count as a ship action
    #my $actioned_ship_string = join( ',', @$ships_actioned );
    my $query = <<SQL;
    SELECT refuel_ship( id ) AS added,
           id,
           max_fuel - current_fuel AS needed
      FROM my_ships
     WHERE current_fuel < max_fuel
SQL
    #$query .= " AND id NOT IN( $actioned_ship_string )" if( scalar( @$ships_actioned ) > 0 );
    my $sth = $handle->prepare( $query );
       $sth->execute() or warn( 'Failed to refuel ships' );
    
    while( my $row = $sth->fetchrow_hashref() )
    {
        #push( @$ships_actioned, $row->{'id'} );
        $fuel -= $row->{'added'};
        print "added " . $row->{'added'} . " fuel to ship " . $row->{'id'} . "\n" if( DEBUG );
    }

    return;
}

sub mine($)
{
    my( $handle ) = @_;
    my $actioned_ship_string = join( ',', @$ships_actioned );
    my $query = <<SQL;
        SELECT MINE( s.id, p.id ) AS result,
               s.id AS ship
          FROM my_ships s
    INNER JOIN planets p
            ON CIRCLE( s.location, s.range ) @> p.location
         WHERE s.name LIKE '%-1'
SQL
    $query .= " AND s.id NOT IN( $actioned_ship_string )" if( scalar( @$ships_actioned ) > 0 );
    my $sth = $handle->prepare( $query );
       $sth->execute() or warn( 'failed to mine' );

    # We cannot assume the mining happened until next tic, we can check the result (boolean) for success though
    while( my $row = $sth->fetchrow_hashref() )
    {
        push( @$ships_actioned, $row->{'ship'} );
    }

    return;
}

sub upgrade($$)
{
    my( $handle, $budget_pct, $role ) = @_;
    
    my $budget = int( $balance * $budget_pct );
    my $role_spec = $ship_design_spec->{$role};
    
    my $query;
    my $upgrade_q;
    
    my $sth;
    my $upgrade_sth;

    my $ship_count_q = <<SQL;
    SELECT s.id
      FROM my_ships s
     WHERE s.name LIKE ( '%-' || ?::VARCHAR )
       AND ( s.attack + s.defense + s.engineering + s.prospecting ) < ?
SQL

    my $code           = MAX_SHIP_SKILL;
    my $max_ship_skill = $public_variable->{$code};
    my $ship_count_sth = $handle->prepare( $ship_count_q );
       $ship_count_sth->bind_param( 1, $role );
       $ship_count_sth->bind_param( 2, $max_ship_skill );
       $ship_count_sth->execute() or warn( 'Failed to get a list of ships to upgrade' );
    
    my $count          = $ship_count_sth->rows();

    if( $count > 0 )
    {
        my $per_ship_budget = int( $budget / $count );
        my $per_spec_ammount = {};

        foreach my $spec( keys %$role_spec )
        {
            my $price    = $price_list->{$spec};
            my $spec_pct = $role_spec->{$spec};
            my $ammount  = int( $per_ship_budget * $spec_pct );
        
            my $number_of_upgrades = int( $ammount / $price );
            $per_spec_ammount->{$spec} = $ammount;
        }

           $query = <<SQL;
        SELECT s.id,
               s.prospecting,
               s.engineering,
               s.defense,
               s.attack
          FROM my_ships s
         WHERE s.id = ?
SQL

           $upgrade_q = <<SQL;
        SELECT UPGRADE( ?, ?, ? ) AS ammount
SQL
           $upgrade_sth = $handle->prepare( $upgrade_q );
           $sth         = $handle->prepare( $query     );
        
        while( my $row = $ship_count_sth->fetchrow_hashref() )
        {
            $sth->bind_param( 1, $row->{'id'} );
            $sth->execute() or warn( 'failed to lookup ship to upgrade' );
            my $row = $sth->fetchrow_hashref();
            
            foreach my $spec( keys %$per_spec_ammount )
            {
                my $spec_lc = lc( $spec );
                my $allowed = $per_spec_ammount->{$spec};
                my $needed  = (  $max_ship_skill * $ship_design_spec->{$role}->{$spec} ) - $row->{$spec_lc};
                
                my $upgrade_amount = 0;
                   $upgrade_amount = $needed if( $allowed >= $needed );
                   $upgrade_amount = $allowed if( $needed > $allowed );
                
                $upgrade_sth->bind_param( 1, $row->{'id'}    );
                $upgrade_sth->bind_param( 2, $spec           );
                $upgrade_sth->bind_param( 3, $upgrade_amount );
                $upgrade_sth->execute() or warn( 'Failed to upgrade ship' );

                my $upgrade_row = $upgrade_sth->fetchrow_hashref();
                my $upgraded    = $upgrade_row->{'ammount'};
                
                my $dec   = ( $upgrade_amount * $row->{$spec_lc} );
                $balance -= $dec if( $upgraded );
                $budget  -= $dec if( $upgraded );
            }
        }
    }
     
    my $code_speed  = MAX_SHIP_SPEED;
    my $code_health = MAX_SHIP_HEALTH;
    my $code_fuel   = MAX_SHIP_FUEL;
    my $code_range  = MAX_SHIP_RANGE;

    my $max_speed   = $public_variable->{$code_speed };
    my $max_health  = $public_variable->{$code_health};
    my $max_fuel    = $public_variable->{$code_fuel  };
    my $max_range   = $public_variable->{$code_range };

       $code_health = MAX_HEALTH;
       $code_speed  = MAX_SPEED;
       $code_fuel   = MAX_FUEL;
       $code_range  = RANGE;

    my $upgrade_specs = { };
    print "budget: $budget\n";
    print "role $role\n";
    if( $role == SHIP_ROLE_CAPITAL and $budget > 0 )
    {
        $query = <<SQL;
    SELECT s.id,
           ? - s.max_speed AS needed_speed,
           ? - s.max_health AS needed_health,
           ? - s.range AS needed_range,
           ? - s.max_fuel AS needed_fuel
      FROM my_ships s
     WHERE s.name LIKE ( '%-' || ?::VARCHAR )
       AND (
                 ( s.max_speed < ?  )
              OR ( s.max_health < ? )
              OR ( s.range < ?      )
              OR ( s.max_fuel < ?   )
           )
SQL

        $sth = $handle->prepare( $query );
        $sth->bind_param( 1, $max_speed  );
        $sth->bind_param( 2, $max_health );
        $sth->bind_param( 3, $max_range  );
        $sth->bind_param( 4, $max_fuel   );
        $sth->bind_param( 5, $role       );
        $sth->bind_param( 6, $max_speed  );
        $sth->bind_param( 7, $max_health );
        $sth->bind_param( 8, $max_range  );
        $sth->bind_param( 9, $max_fuel   );
        
        # TODO: Modify healing upgrades such that it doesn't interfere with capital ship movement
        $upgrade_specs->{$code_speed} = 'needed_speed';
        #$upgrade_specs->{$code_health} = 'needed_health';
        $upgrade_specs->{$code_range} = 'needed_range';
        $upgrade_specs->{$code_fuel} = 'needed_fuel';
    }

    if( $role == SHIP_ROLE_HEALER and $budget > 0 )
    {
        $query = <<SQL;
    SELECT s.id, 
           ? - s.max_health AS needed_health,
           ? - s.range AS needed_range
      FROM my_ships s
     WHERE s.name LIKE ( '%-' || ?::VARCHAR )
       AND (
                 ( s.max_health < ? )
              OR ( s.range < ?      )
           )
SQL

        $sth = $handle->prepare( $query );
        $sth->bind_param( 1, $max_health );
        $sth->bind_param( 2, $max_range  );
        $sth->bind_param( 3, $role       );
        $sth->bind_param( 4, $max_health );
        $sth->bind_param( 5, $max_range  );

        #$upgrade_specs->{$code_health} = 'needed_health';
        $upgrade_specs->{$code_range} = 'needed_range';
    }

    if( $role == SHIP_ROLE_DEFENSE and $budget > 0 )
    {
        $query = <<SQL;
    SELECT s.id, 
           ? - s.max_health AS needed_health,
           ? - s.range AS needed_range
      FROM my_ships s
     WHERE s.name LIKE ( '%-' || ?::VARCHAR )
       AND (
                 ( s.max_health < ? )
              OR ( s.range < ?      )
           )
SQL

        $sth = $handle->prepare( $query );
        $sth->bind_param( 1, $max_health );
        $sth->bind_param( 2, $max_range  );
        $sth->bind_param( 3, $role       );
        $sth->bind_param( 4, $max_health );
        $sth->bind_param( 5, $max_range  );

        #$upgrade_specs->{$code_health} = 'needed_health';
        $upgrade_specs->{$code_range} = 'needed_range';
    }

    if( $role == SHIP_ROLE_MINER and $budget > 0 )
    {
        $query = <<SQL;
    SELECT s.id,
           ? - s.max_health AS needed_health
      FROM my_ships s
     WHERE s.name LIKE ( '%-' || ?::VARCHAR )
       AND s.max_health < ?
SQL

        $sth = $handle->prepare( $query );
        $sth->bind_param( 1, $max_health );
        $sth->bind_param( 2, $role       );
        $sth->bind_param( 3, $max_health );
        
        #$upgrade_specs->{$code_health} = 'needed_health';
    }

    my $upgrade_count = scalar( keys %$upgrade_specs );

    if( $upgrade_count > 0 )
    {
        $sth->execute() or warn( 'Failed to get secondary upgrades' );
        my $ship_count = $sth->rows();

        $tic_stats->{'upgrade_needed'}->{$role} = 0 if( $ship_count == 0 and $ship_count_sth->rows() == 0 );
        return if( $ship_count == 0 );
        
        $sth->execute() or warn( 'Failed to determine ships in need of upgrade' );
        my $per_ship_budget = int( $budget / $ship_count );
        my $per_spec_budget = int( $per_ship_budget / $upgrade_count );
           $upgrade_q = <<SQL;
        SELECT UPGRADE( ?, ?, ? ) AS ammount
SQL
           $upgrade_sth = $handle->prepare( $upgrade_q );

        while( my $row = $sth->fetchrow_hashref() )
        { 
            my $ship_id = $row->{'id'};

            foreach my $spec_code( keys %$upgrade_specs )
            {
                my $sql_col     = $upgrade_specs->{$spec_code};
                my $price       = $price_list->{$spec_code};
                my $needed      = $row->{$sql_col};
                my $allotted    = int( $per_spec_budget / $price );

                my $actual      = 0;
                   $actual      = $allotted if( $needed > $allotted );
                   $actual      = $needed if( $allotted > $needed );
                
                   $upgrade_sth->bind_param( 1, $ship_id   );
                   $upgrade_sth->bind_param( 2, $spec_code );
                   $upgrade_sth->bind_param( 3, $actual    );
                   $upgrade_sth->execute() or warn( 'Failed to upgrade ship' );
                my $upgrade_row = $upgrade_sth->fetchrow_hashref();
                my $upgraded = $upgrade_row->{'ammount'};
                
                my $dec = ( $actual * $price );

                $balance -= $dec if( $upgraded );
                $budget  -= $dec if( $upgraded );
            }
        }
    }

    return;
}

sub capital_control($)
{
    my( $handle ) = @_;

    # Find stationary capital ships near a captured planet, send them off
    my $actioned_ship_string = join( ',', @$ships_actioned );
    
    # Do a couple things:
    #   Keep in flight ships en route
    #   Capture planets once in flight ships arrive
    my $query = <<SQL;
    WITH tt_capital_fleets AS
    (
        SELECT f.id AS fleet_id
          FROM my_fleets f
         WHERE f.name LIKE '%_capital'
    ),
    tt_stationary_fleets AS
    (
        SELECT tt.fleet_id,
               pg_temp.get_center( array_agg( s.location ) ) AS fleet_location
          FROM tt_capital_fleets tt
    INNER JOIN my_ships s
            ON s.fleet_id = tt.fleet_id
           AND s.speed = 0
           AND s.max_speed::FLOAT > ( ?::FLOAT * 0.75 )
           AND s.name LIKE '%-3'
SQL
    $query .= " AND s.id NOT IN( $actioned_ship_string ) " if( scalar( @$ships_actioned ) > 0 );
    $query .= <<SQL;
    INNER JOIN planets p
            ON CIRCLE( s.location, s.range ) @> p.location
           AND p.conqueror_id = ?
      GROUP BY tt.fleet_id
        HAVING COUNT( s.id ) = ?
    ),
    tt_migration_candidates AS
    (
        SELECT p.id AS planet_id,
               tt.fleet_id,
               p.location <-> tt.fleet_location AS distance
          FROM tt_stationary_fleets tt
    INNER JOIN planets p
            ON p.conqueror_id IS NULL
      ORDER BY tt.fleet_id DESC,
               p.location <-> tt.fleet_location ASC
    )
        SELECT DISTINCT ON( tt.fleet_id )
               tt.fleet_id,
               tt.planet_id,
               tt.distance
          FROM tt_migration_candidates tt
SQL
    my $sth = $handle->prepare( $query );
       $sth->bind_param( 1, $public_variable->{MAX_SHIP_SPEED} ); 
       $sth->bind_param( 2, $player_id );
       $sth->bind_param( 3, CAPITAL_NUMBER );
       $sth->execute() or warn( 'Failed to get list of stationary fleets' );

    my $move_q = <<SQL;
        SELECT SHIP_COURSE_CONTROL(
                   s.id,
                   LEAST(
                        ( s.current_fuel::FLOAT / 2 )::INTEGER,
                        p.location <-> s.location
                   )::INTEGER,
                   NULL,
                   p.location
               ) AS result,
               s.id
          FROM my_ships s
    INNER JOIN planets p
            ON p.id = ?
         WHERE s.fleet_id = ? 
SQL
    my $move_sth = $handle->prepare( $move_q );
    
    while( my $row = $sth->fetchrow_hashref() )
    {
        print "Attempting to command move...\n" if( DEBUG );
        
        # command ships to move
        my $fleet_id    = $row->{'fleet_id' };
        my $planet_id   = $row->{'planet_id'};
        my $distance    = $row->{'distance' };
        
        $move_sth->bind_param( 1, $planet_id );
        $move_sth->bind_param( 2, $fleet_id  );
        $move_sth->execute() or warn( 'Failed to command ship to move' );

        my $count         = $move_sth->rows();
        my $success_count = 0;
        
        while( my $move_row = $move_sth->fetchrow_hashref() )
        {
            my $success  = $move_row->{'result'};
            my $ship_id  = $move_row->{'id'};

            if( $success )
            {
                $success_count++;
                print "Successfully commanded $ship_id to move to $planet_id\n" if( DEBUG );
            }
            else
            {
                print "Failed to move ship $ship_id to $planet_id\n" if( DEBUG );
            }
        }

        $capitals_in_flight->{$fleet_id} = $planet_id if( $success_count == $count );
    }


    foreach my $fleet_id( keys %$capitals_in_flight )
    {
        my $planet_id = $capitals_in_flight->{$fleet_id};
        # Capture if we are within range of our destination planet
        my $capture_q = <<SQL;
        SELECT MINE( s.id, p.id ) AS result,
               s.id
          FROM my_ships s
    INNER JOIN planets p
            ON CIRCLE( s.location, s.range ) @> p.location
           AND ( p.conqueror_id IS NULL OR p.conqueror_id != ? )
           AND p.id = ?
         WHERE s.fleet_id = ?
SQL
           $capture_q  .= " AND s.id NOT IN( $actioned_ship_string ) " if( scalar( @$ships_actioned ) > 0 );
        my $capture_sth = $handle->prepare( $capture_q );
           $capture_sth->bind_param( 1, $player_id );
           $capture_sth->bind_param( 2, $planet_id );
           $capture_sth->bind_param( 3, $fleet_id  );
           $capture_sth->execute() or warn( 'Failed to attempt to capture planet' );
        
        while( my $row = $capture_sth->fetchrow_hashref() )
        {
            my $ship   = $row->{'id'    };
            my $result = $row->{'result'};

            print "Ship $ship attempted capture of planet $planet_id with result $result\n" if( DEBUG );
            if( $result )
            {
                $tic_stats->{'ships_needed'}->{1} = 1;
                $tic_stats->{'ships_needed'}->{2} = 1;
                $tic_stats->{'ships_needed'}->{3} = 1;
                $tic_stats->{'ships_needed'}->{4} = 1;
            }
        }
    }

    return;
}

sub attack_defense_controller($)
{
    my( $handle ) = @_;
    my $actioned_ships_string = join( ',', @$ships_actioned ) if( @$ships_actioned > 0 );
    my $query = <<SQL;
        SELECT sir.id AS target,
               array_agg( s.id ORDER BY s.attack DESC ) AS potential_attackers
          FROM ships_in_range sir
    INNER JOIN my_ships s
            ON s.id = sir.ship_in_range_of
           AND s.current_health > 0
           AND (
                    s.name LIKE '%-3'
                 OR s.name LIKE '%-2'
               )
SQL
    $query .= " AND s.id NOT IN( $actioned_ships_string ) " if( scalar( @$ships_actioned ) > 0 );
    $query .= " GROUP BY sir.id ";
    my $sth = $handle->prepare( $query );
       $sth->execute() or warn( 'Failed to get threat list' );

    while( my $row = $sth->fetchrow_hashref() )
    {
        my $target              = $row->{'target'             };
        my $potential_attackers = $row->{'potential_attackers'};
    }

    return;
}

while(1)
{
    my $lhandle = DBI->connect( LDBASE_CONNECT_PERL, $username, $password, { AutoCommit => 1, ShowErrorStatement => 1 } );
    my $handle = $lhandle;
    &initialize($handle);
    
    while( &state_sync( $handle ) )
    {
        # TODO:
        #  Repair damaged ships
        #  Refuel Ships
        #  Mine
        #  Use balance to create miners up to planet mine_limit
        #  Use balance to upgrade miners up to max for role
        #  Use balance to create defensive ships
        #  Use balance to upgrade defensive ships uo to max for role
        #  Use balance to create capital ships
        #  Use balance to upgrade capital ships up to max for role
        #  Deploy capital ships to nearest neighbor
        #  Handle Attack events
        print "New tic detected\n" if( DEBUG );
        $ships_actioned = [ ];
        &manage_fuel_conversion( $handle );
        &repair_ships( $handle );
        &refuel_ships( $handle );
        &mine( $handle );
        &build_miners( $handle ) if( $tic_stats->{'ships_needed'}->{1} );
        &upgrade( $handle, 0.30, SHIP_ROLE_MINER ) if( $tic_stats->{'upgrades_needed'}->{1} );
        &build_healer( $handle ) if( $tic_stats->{'ships_needed'}->{4} );
        &upgrade( $handle, 0.10, SHIP_ROLE_HEALER ) if( $tic_stats->{'upgrades_needed' }->{4} );
        &build_defense( $handle ) if( $tic_stats->{'ships_needed'}->{2} );
        &upgrade( $handle, 0.30, SHIP_ROLE_DEFENSE ) if( $tic_stats->{'upgrades_needed'}->{2} );
        &build_capital( $handle ) if( $tic_stats->{'ships_needed'}->{3} );
        &upgrade( $handle, 0.30, SHIP_ROLE_CAPITAL ) if( $tic_stats->{'upgrades_needed'}->{3} );
        &manage_balance_conversion( $handle );
        &refuel_ships( $handle );
        &repair_ships( $handle );
        &capital_control( $handle );
        &attack_defense_controller( $handle );
    }
    $handle->disconnect();

    sleep WAIT_TIME;
}
