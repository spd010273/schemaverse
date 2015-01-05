#!/usr/bin/perl

use utf8;
use strict;
use warnings;

use DBI;
use GD;
use Getopt::Std;
use Data::Dumper;

use GD::Graph;
use GD::Image;
use GD::Graph::points;

use constant SCALE => 10000; # Constant that scales down the real map to save RAM and image size
use constant P_MUL => 0.0001; # Planet diameter (px)
use constant DEBUG => 1;
use constant GAUSS => 150; # Number of points in Gaussian Distribution
#use constant Z_SCL =>

sub usage(;$)
{
    my( $message ) = @_;

    warn( "$message\n" ) if( $message );
    warn( "Usage:\n"   );
    warn( " $0 -U username -w password -p player_id -V  (verbose flag)\n" );
    exit 1;
}

sub main()
{
    # Get and validate arg
    our( $opt_p, $opt_U, $opt_w, $opt_V );
    &usage( "Invalid args" ) unless( getopts( 'p:U:w:V' ) );
    my $player_id   = $opt_p;
    my $username    = $opt_U;
    my $password    = $opt_w;
    die( "Invalid player_id" ) unless( $player_id and $player_id =~ /^\d+$/ );
    die( "Invalid username"  ) unless( $username and length( $username > 0 ) );
    die( "Invalid password"  ) unless( $password and length( $password > 0 ) );
    
    my $verbose   = 0;
       $verbose   = 1 if( $opt_V or DEBUG );
    
    # TODO: Modify to take in username, port, host, and pass via CLI, config file, and/or read .pgpass?
    my $handle    = DBI->connect(
                       'dbi:Pg:'
                     . 'dbname=schemaverse;'
                     . 'host=localhost;'
                     . 'port=5432',
                       $username,
                       $password,
                       {
                            AutoCommit => 1,
                            ShowErrorStatement => 1
                       }
                    ) or die( "Couldn't connect to database\n" );
    
    my $SCALE     = SCALE;
    my $bounds_q  = <<SQL;
        SELECT MAX( location_x::FLOAT / $SCALE ) AS max_x,
               MAX( location_y::FLOAT / $SCALE ) AS max_y,
               MIN( location_x::FLOAT / $SCALE ) AS min_x,
               MIN( location_y::FLOAT / $SCALE ) AS min_y,
               STDDEV( mine_limit ) AS stddev_mine,
               MAX( mine_limit ) AS max_mine,
               MIN( mine_limit ) AS min_mine, 
               AVG( mine_limit ) AS avg_mine
          FROM planets
SQL

    print "Getting map bounds...\n" if( $verbose );

    my $bounds_sth = $handle->prepare( $bounds_q     );
       $bounds_sth->execute() or die( "Failed to get graph bounds\n" );
    my $bounds_row = $bounds_sth->fetchrow_hashref();
    my $width      = ( abs( $bounds_row->{'max_x'   } ) + abs( $bounds_row->{'min_x'} ) );
    my $height     = ( abs( $bounds_row->{'max_y'   } ) + abs( $bounds_row->{'min_y'} ) );
    my $max_x      =   abs( $bounds_row->{'max_x'   } );
    my $max_y      =   abs( $bounds_row->{'max_y'   } );
   
    # Grab stats for later use 
    my $stddev_mine  = $bounds_row->{'stddev_mine'};
    my $max_mine     = $bounds_row->{'max_mine'   };
    my $min_mine     = $bounds_row->{'min_mine'   };
    my $avg_mine     = $bounds_row->{'avg_mine'   };

    my $planet_query = <<SQL;
        SELECT ( ( location_x::FLOAT / $SCALE ) + ? )::INTEGER AS location_x,
               ( ( location_y::FLOAT / $SCALE ) + ? )::INTEGER AS location_y,
               COALESCE( conqueror_id, 0 )        AS conqueror_id,
               id                                 AS planet_id,
               mine_limit                         AS mine_limit
          FROM planets
      ORDER BY conqueror_id NULLS LAST
SQL

    
    # Build Image
    print "Building GD::Image...\n" if( $verbose );
    my $image       = GD::Image->new( $width, $height );
    my $image_file  = 'image.png';
    my $planet_size = 10; # Default
       $planet_size = int( SCALE * P_MUL ) if( SCALE and P_MUL and SCALE =~ /^\d+$/ and P_MUL =~ /^\d+$/ ); # Verify that we are not configured incorrectly

    # Allocate Colors, build color table for enemies ( To differentiate between multiple enemies )
    my $black = $image->colorResolve( 0,   0,   0   ); # Space Fill
    my $blue  = $image->colorResolve( 0,   0,   255 ); # Empty Planets
    my $green = $image->colorResolve( 0,   255, 0   ); # Friendly Planets / Ships
    my $red   = $image->colorResolve( 255, 0,   0   );
       $image->fill( 0, 0, $black );

    my @enemy_colors;

    # Stagger red index to generate enemy color table
    for( my $r = 255; $r > 0; $r = $r - 15 )
    {
        my $color = $image->colorResolve( $r, 0, 0 ) || undef;
        push( @enemy_colors, $color );
    }

    
    print "Getting points...\n" if( $verbose );
    print "XMAX: $max_x YMAX: $max_y\n" if( DEBUG );
    
    my $planet_sth = $handle->prepare( $planet_query );
       $planet_sth->bind_param( 1, $max_x );
       $planet_sth->bind_param( 2, $max_y );
       $planet_sth->execute() or die( "Failed to get planet list\n" );

    my $current_enemy_color = undef; # Pointer to current enemy color
    my $last_enemy_id       = 0;     # Multi-use one shot to trigger new enemy color pointer 
    my $planet_count        = 0;
    my $data_hash           = { };   # Store query results for later use (within the same tic loop)
    my $gaussian_map        = { };   # We will keep track of several joint normal distributions.
    my $planet_map          = { };

    # Generate background pixilation
    while( my $row = $planet_sth->fetchrow_hashref() )
    {
        my $x           = $row->{'location_x'  };
        my $y           = $row->{'location_y'  };
        my $id          = $row->{'planet_id'   };
        my $conqueror   = $row->{'conqueror_id'};
        my $mine_limit  = $row->{'mine_limit'  };
        my $color;

        if( $conqueror )
        {
            if( $conqueror == $player_id )
            {
                $color = $green; # Indicate planet is ours
            }
            else
            {
                if( !$last_enemy_id  or ( $last_enemy_id and ( $last_enemy_id != $conqueror ) ) )
                {
                    # Need a new enemy color ID since we've seen a new conqueror_id
                    $current_enemy_color = shift( @enemy_colors );
                    $last_enemy_id       = $conqueror;
                }
                
                $color = $current_enemy_color;
            }
        }
        else
        {
            $color = $blue; # Indicate planet is available
        }

        $data_hash->{$id} = {
                                'x'          => $x,
                                'y'          => $y,
                                'conqueror'  => $conqueror,
                                'mine_limit' => $mine_limit
                            };
        
        #$image->filledEllipse( $x, $y, $planet_size, $planet_size, $color );
        $planet_map->{$x}->{$y} = $color;
        $planet_count++;
        my $spreader = 1; # Lower to increase Gaussian function's spread, need to increase GAUSS accordingly

        print "Running Gaussian function on planet $id...\n" if( $verbose );
        my $z = ( $mine_limit - $avg_mine ) / $stddev_mine; # Store the Z-score
        my $t = ( ( $z * 10 ) + 50 ) / $spreader; # Generate 0-10 t-score
        my $a = 1; # / ( $z * sqrt( 2 * 3.14 ) );
        
        for( my $dx = $x - GAUSS; $dx < $x + GAUSS; $dx++ )
        {
            #next if( $dx <= 0 or $dx >= $max_x );

            for( my $dy = $y - GAUSS; $dy < $y + GAUSS; $dy++ )
            {
                #next if( $dy <= 0 or $dy >= $max_y );
                my $distance = sqrt( ( $dx - $x )**2 + ( $dy - $y )**2 );
                next if( $distance > GAUSS );

                my $delta_x2 = ( ( $dx - $x )**2 ) / ( 2 * $t**2 );
                my $delta_y2 = ( ( $dy - $y )**2 ) / ( 2 * $t**2 );
                my $value    = abs( $a * exp( -( $delta_x2 + $delta_y2 ) ) );
                my $existing = $gaussian_map->{$dx}->{$dy};
                   $existing = 0 unless( $existing and $existing > 0 );
                   $existing = $existing + $value;

                $gaussian_map->{$dx}->{$dy} = $existing;
            }
        }
    }
    
    print "Planet count: $planet_count\n" if( DEBUG );
    $planet_sth->finish();
    my $allocated_colors = { };
    my $sum     = 0;  
    my $count   = 0;
    my $min     = 0;
    my $max     = 0;
        
    # Compute mean and number of non-zero Gaussian values ( to avoid weighting empty map areas )
    foreach my $x( keys %$gaussian_map )
    {
        foreach my $y( keys %{$gaussian_map->{$x}} )
        {
            my $value = $gaussian_map->{$x}->{$y};
               $sum  += $value if( $value );
               $count++ if( $value );
               $min   = $value if( $value < $min );
               $max   = $value if( $value > $max );
        }
    }

    print "Min: $min Max: $max\n";
    my $newmax   = $max + abs( $min );
    my $mean     = $sum / $count;
    my $rgb_mult = 255 / $newmax; 
    print "newmax: $newmax, rgbmult $rgb_mult\n";
    
    foreach my $x( keys %$gaussian_map )
    {
        foreach my $y( keys %{$gaussian_map->{$x}} )
        {
            my $value       = $gaussian_map->{$x}->{$y};
            my $rgb_score   = int( $rgb_mult * ( $value + abs( $min ) ) ); # T-Score scaled from 0 - 255 
               $rgb_score   = 255 if( $rgb_score > 255 );
            my $color = $allocated_colors->{$value};
               $color = $image->colorResolve( $rgb_score, 0, 0 ) unless( $color );
               $allocated_colors->{$rgb_score} = $color if( $color );
               $image->setPixel( $x, $y, $color ) if( $color );
        }
    }
    
    foreach my $x( keys %$planet_map )
    {
        foreach my $y( keys %{$planet_map->{$x}} )
        {
            # Place planet marker
            my $planet_color = -1;
               $planet_color = $planet_map->{$x}->{$y} if( exists( $planet_map->{$x} ) and exists( $planet_map->{$x}->{$y} ) );

            if( $planet_color > -1 )
            {
                $image->filledEllipse( $x, $y, $planet_size, $planet_size, $planet_color );
            }
        }
    }

    # Write out GD::Image file
    print "Writing image out...\n" if( $verbose );
    unlink( $image_file ) if( -f $image_file );
    open( IMG, ">$image_file" ) or die( "Couldn't open handle to $image_file: $!\n" );
    binmode( IMG );
    print( IMG $image->png() );
    close( IMG );
}

&main();
exit 0;
