#! /usr/bin/env perl
use strict;
use warnings;
use Test::More;

use_ok( 'Date::RetentionPolicy' ) or BAIL_OUT;
my $epoch_2018= 1514764800;

my @tests= (
	{
		name   => '4x daily for 2w, 1x daily for 2mo, 1x weekly for 1y',
		retain => [
			{ interval => { hours => 6 }, duration => { days   => 14 } },
			{ interval => { days  => 1 }, duration => { months =>  2 } },
			{ interval => { days  => 7 }, duration => { years  =>  1 } },
		],
		dates  => [
			every_x('2018-01-01 00:00', '2017-01-01 00:01', hours => 6),
		],
		keep   => [
			every_x('2018-01-01 00:00', '2017-12-18 00:01', hours => 6),
			every_x('2017-12-17 12:00', '2017-11-01 00:01', days => 1),
			every_x('2017-10-26 12:00', '2017-01-01 00:01', days => 7),
			'2017-01-01T06:00:00' # half interval, still finds nearest
		],
		reach  => .5,
	},
);
for my $t (@tests) {
	subtest $t->{name} => sub {
		my $rp= new_ok( 'Date::RetentionPolicy', [
			retain => $t->{retain},
			reference_date => $epoch_2018,
			reach_factor => $t->{reach}
		] );
		my @list= @{ $t->{dates} };
		$rp->prune(\@list);
		is_deeply( \@list, $t->{keep}, 'kept' );
	};
}

sub every_x {
	my ($from, $until, @interval)= @_;
	my @ret;
	my $d0= DateTime::Format::Flexible->parse_datetime($from);
	my $dn= DateTime::Format::Flexible->parse_datetime($until);
	while ($d0 >= $dn) {
		push @ret, "$d0";
		$d0->subtract(@interval);
	}
	@ret;
}

done_testing;
