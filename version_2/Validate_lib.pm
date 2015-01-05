package Validate_lib;

use strict;
use Exporter();

use vars qw( @ISA @EXPORT );

use constant DEBUG => 1;

# Validate_lib.pm written to the tune of common/functions/validate_lib.php
# Please note: All functions take the following:
# single scalar
# hashref as first parameter, key as second
# arrayref as first parameter, index as second

@ISA = qw( Exporter );

@EXPORT = qw(
                &is_valid_date
                &is_neadwerx_email
                &is_valid_email
                &trim_and_shorten
                &is_missing_or_undef
                &is_missing_or_empty
                &is_number_positive
                &is_number_negative
                &is_number
                &is_number_in_range
                &is_text_empty
                &is_integer
                &is_integer_positive
                &is_integer_negative
                &is_true
                &is_false
                &is_boolean
            );

sub _is_valid_integer_parameter($)
{
    #Internal-Only
    #Validates parameters of this library's functions
    my( $val ) = @_;
    return 0 unless( defined $val );
    return 0 unless( length( $val ) > 0 );

    return 1 if( $val =~ /^-?([0-9]|([1-9][0-9]+))$/ );

    return 0;
}

sub _is_valid_numeric_parameter($)
{
    #Internal-Only
    #Validates parameters of this library's functions
    my( $val ) = @_;
    return 0 unless( defined $val );
    return 0 unless( length( $val ) > 0 );

    return 1 if( $val =~ /^-?([0-9]|([1-9][0-9]+))(\.\d+)?$/ );

    return 0;
}

sub _trim($)
{
    #Internal-Only ( as to not conflict with Util::&trim($) )
    my( $val ) = @_;

    return undef unless( defined $val );

    $val =~ s/^\s+//;
    $val =~ s/\s+$//;

    return $val;
}

sub _get_value($;$)
{
    #Internal-Only
    #This takes the parameter list of library functions and returns either:
    # $ref,
    # $ref->[$ind],
    # $ref->{$ind},
    #  or
    # undef (if there is a problem)
    my( $ref, $ind ) = @_;

    # A little paranoia in this function
    return undef unless( defined $ref );

    if( ref( $ref ) eq 'SCALAR' )
    {
        return $$ref;
    }
    elsif( ref( $ref ) eq 'ARRAY' )
    {
        unless( &_is_valid_integer_parameter( $ind ) )
        {
            warn "Validate_lib::&_get_value(\$;\$) received ARRAYREF with bad \$ind\n" if( DEBUG and -t STDIN );
            return undef;
        }

        return undef unless( defined $ref->[$ind] );

        return $ref->[$ind];
    }
    elsif( ref( $ref ) eq 'HASH' )
    {
        unless( defined $ind )
        {
            warn "Validate_lib::&_get_value(\$;\$) received HASHREF with \$ind = undef\n" if( DEBUG and -t STDIN );
            return undef;
        }

        return undef unless( defined $ref->{$ind} );
        return $ref->{$ind};
    }
    elsif( ref( $ref ) eq '' )
    {
        return $ref;
    }

    return undef;
}

sub _set_value($$;$)
{
    #Internal-Only
    #This sets parameters ( useful for trim_and_shorten, possibly others )
    # return 1 when the following is possible:
    #  $$ref = $val;
    #  $ref->[$ind] = $val;
    #  $ref->{$ind} = $val;
    #  $ref = $val;
    # return 0 if there's a problem
    my( $ref, $val, $ind ) = @_;

    return 0 unless( defined $ref );

    if( ref( $ref ) eq 'SCALAR' )
    {
        $$ref = $val;
        return 1;
    }
    elsif( ref( $ref ) eq 'ARRAY' )
    {
        unless( &_is_valid_integer_parameter( $ind ) )
        {
            warn "Validate_lib::&_set_value(\$\$;\$) received ARRAYREF with bad \$ind\n" if( DEBUG and -t STDIN );
            return 0;
        }

        return 0 unless( defined $ref->[$ind] );
        return 0 unless(  exists $ref->[$ind] );
        $ref->[$ind] = $val;
        return 1;
    }
    elsif( ref( $ref ) eq 'HASH' )
    {
        unless( defined $ind and length( $ind ) > 0 )
        {
            warn "Validate_lib::&_set_value(\$\$;\$) received HASHREF with \$ind = undef\n" if( DEBUG and -t STDIN );
            return 0;
        }

        return 0 unless( defined $ref->{$ind} );
        return 0 unless(  exists $ref->{$ind} );
        $ref->{$ind} = $val;
        return 1;

    }
    elsif( ref( $ref ) eq '' )
    {
        $ref = $val;
        return $ref;
    }

    return 0;
}

sub is_valid_date($;$)
{
    my( $ref, $ind ) = @_;
    my $val = &_get_value( $ref, $ind );

    return 0 unless( defined $val );

    return 1 if( $val =~ /^\d{4}-\d{2}-\d{2}$/                     ); # ISO 8601 Date YYYY-MM-DD
    return 1 if( $val =~ /^\d{4}-\d{2}-\d{2}\s\d{2}[-:\s]\d{2}[-:\s]\d{2}?$/ ); # YYYY-MM-DD HH:MM:SS
    return 1 if( $val =~ /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(\.\d+)?Z$/        ); # ISO 8601 date time in UTC YYYY-MM-DDTHH:MMZ
    return 1 if( $val =~ /^\d{4}-W\d{2}-\d{1}$/                    ); # ISO 8601 date with week number YYYY-Www-D
    return 1 if( $val =~ /^\d{4}-\d{3}$/                           ); # ISO 8601 ordinal date YYYY-OOO
    return 1 if( $val =~ /^\d{1,2}[-\s\/]+\d{1,2}[-\s\/]+\d{2,4}$/ ); # US MM/DD/YYYY
    return 1 if( $val =~ /^\d{4}[-\s\/\.]+\d{2}[-\s\/\.]+\d{2}$/   ); # Expanded ISO 8601 YYYY/MM/DD or
                                                                    #  YYYY MM DD or YYYY.MM.DD
    #Needs more regexes
    return 0;
}

sub is_neadwerx_email($;$)
{
    my( $ref, $ind ) = @_;
    my $val = &_get_value( $ref, $ind );

    return 0 unless( defined $val );
    return 1 if( $val =~ /\w+\@neadwerx\.com$/ );
    return 0;
}

sub is_valid_email($;$)
{
    my( $ref, $ind ) = @_;
    my $val = &_get_value( $ref, $ind );

    return 0 unless( defined $val );
    return 1 if( $val =~ /^.+\@.+\..+$/ );
    return 0;
}

sub trim_and_shorten($$;$)
{
    my( $ref, $len, $ind ) = @_;
    my $val = &_get_value( $ref, $ind );

    return undef unless( &_is_valid_integer_parameter( $len ) );
    return undef unless( $len > 0     );
    return undef unless( defined $val );
    return undef unless( length( $val ) >= $len );

    $val = &_trim( $val );
    $val = substr( $val, 0, $len );
    $val = &_set_value( $ref, &_trim( $val ), $ind );
    return $val if( $val );
    return 0;
}

sub is_missing_or_undef($;$)
{
    my( $ref, $ind ) = @_;
    my $val          = &_get_value( $ref, $ind );

    return 1 unless( defined $val );

    return 0;
}

sub is_missing_or_empty($;$)
{
    my( $ref, $ind ) = @_;
    my $val          = &_get_value( $ref, $ind );

    return 1 unless( defined $val );
    return 1 if( length( $val ) == 0 );

    return 0;
}

sub is_number_positive($;$)
{
    my( $ref, $ind ) = @_;
    my $val          = &_get_value( $ref, $ind );

    return 0 unless( defined $val );
    return 0 unless( &_is_valid_numeric_parameter( $val ) );

    return 1 if( $val > 0 );

    return 0;
}

sub is_number_negative($;$)
{
    my( $ref, $ind ) = @_;
    my $val          = &_get_value( $ref, $ind );

    return 0 unless( defined $val );
    return 0 unless( &_is_valid_numeric_parameter( $val ) );

    return 1 if( $val < 0 );

    return 0;
}

sub is_number($;$)
{
    my( $ref, $ind ) = @_;
    my $val          = &_get_value( $ref, $ind );

    return 0 unless( defined $val     );
    return 0 unless(  length $val > 0 );

    return 1 if( $val =~ /^-?([0-9]|([1-9][0-9]+))(\.\d+)?$/ );

    return 0;
}

sub is_number_in_range($$$;$)
{
    my( $ref, $min, $max, $ind ) = @_;
    my $val = &_get_value( $ref, $ind );

    return 0 unless( defined $val );
    return 0 unless( &_is_valid_numeric_parameter( $val ) );
    return 0 unless( &_is_valid_numeric_parameter( $min ) );
    return 0 unless( &_is_valid_numeric_parameter( $max ) );
    return 0 if( $max <= $min );

    return 1 if( $min < $val and $val < $max );

    return 0;

}

sub is_text_empty($;$)
{
    my( $ref, $ind ) = @_;
    my $val          = &_get_value( $ref, $ind );

    return 1 unless( defined $val );

    return 1 if( length( $val ) == 0 );

    return 0;
}

sub is_integer($;$)
{
    my( $ref, $ind ) = @_;
    my $val          = &_get_value( $ref, $ind );

    return 0 unless( defined $val );

    return 1 if( $val =~ /^-?([0-9]|([1-9][0-9]+))$/ );

    return 0;
}

sub is_integer_positive($;$)
{
    my( $ref, $ind ) = @_;
    my $val          = &_get_value( $ref, $ind );

    return 0 unless( defined $val );
    return 0 unless( &_is_valid_integer_parameter( $val ) );

    return 1 if( $val > 0 );

    return 0;
}

sub is_integer_negative($;$)
{
    my( $ref, $ind ) = @_;
    my $val          = &_get_value( $ref, $ind );

    return 0 unless( defined $val );
    return 0 unless( &_is_valid_integer_parameter( $val ) );

    return 1 if( $val < 0 );

    return 0;
}

sub is_true($;$)
{
    my( $ref, $ind ) = @_;
    my $val          = &_get_value( $ref, $ind );

    return 0 unless( defined $val );

    return 1 if( $val =~ /^\d{1}$/ and $val == 1 );
    return 1 if( $val =~ /^[t1T]$/ );
    return 1 if( $val =~ /^true$/i );

    return 0;
}

sub is_false($;$)
{
    my( $ref, $ind ) = @_;
    my $val          = &_get_value( $ref, $ind );

    return 0 unless( defined $val );

    return 1 if( $val =~ /^\d{1}$/ and $val == 0 );
    return 1 if( $val =~ /^[f0F]$/               );
    return 1 if( $val =~ /^false$/i              );

    return 0;
}

sub is_boolean($;$)
{
    my( $ref, $ind ) = @_;
    my $val          = &_get_value( $ref, $ind );

    return 0 unless( defined $val );

    return 1 if( &is_true( $val ) or &is_false( $val ) );

    return 0;
}

1;
