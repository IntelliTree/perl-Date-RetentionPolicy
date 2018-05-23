package Date::RetentionPolicy;

use Moo;
use Scalar::Util 'looks_like_number';
use DateTime;
use DateTime::Format::Flexible;

=head1 SYNOPSIS

  my $rp= Date::RetentionPolicy->new(
    retain => [
      { interval => { hours => 6 }, duration => { months => 3 } },
      { interval => { days  => 1 }, duration => { months => 6 } },
      { interval => { days  => 7 }, duration => { months => 9 } },
    ]
  );
  
  my $dates= [ '2018-01-01 03:23:00', '2018-01-01 09:45:00', ... ];
  my $pruned= $rp->prune($dates);
  for (@$pruned) {
    # delete the backup dated $_
    ...
  }

=head1 DESCRIPTION

Often when making backups of a thing, you want to have more frequent snapshots
for a near time window, but don't need that frequency once they reach a certain
age, and want to delete some of them to save space.

The problem of deciding which snapshots to delete is non-trivial because
backups often don't complete on a timely schedule (despite being started on
a schedule) or have discontinuities from production mishaps, and it would be
bad if your script wiped out the only backup in an interval just because it
didn't look like one of the "main" timestamps.  Also it would be bad if the
jitter from the time zone or time of day that you run the pruning process
caused the script to round differently and delete the backups it had
previously decided to keep.

This module uses an algorithm where you first define the intervals which
should retain a backup, then assign the existing timestamps to those intervals
(possibly reaching across the interval boundary a bit in order to preserve
a nearby timestamp; see L<reach_factor>) thus making an intelligent decision
about which timestamps to keep.

=head1 DATES

This module currently depends on DateTime, but I'm happy to accept patches
to allow it to work with other Date classes.

=head1 ATTRIBUTES

=head2 retain

An arrayref of specifications for what to preserve.  Each element should be a
hashref containing C<duration> and C<interval>.  C<duration> specifies how far
backward from L</reference_date> to apply the intervals, and C<interval>
specifies the time difference between the backups that need preserved.

As an example, consider

  retain => [
    { interval => { days => 1 }, duration => { days => 20 } },
    { interval => { hours => 1 }, duration => { hours => 48 } },
  ]

This will attempt to preserve timestamps near the marks of L</reference_date>,
an hour before that, an hour before that, and so on for the past 48 hours.
It will also attempt to preserve L</reference_date>, a day before that, a day
before that, and so on for the past 20 days.

There is another setting called L</reach_factor> that determines how far from
the desired timestamp the algorithm will look for something to preserve.  The
default C<reach_factor> of C<0.5> means that it will scan from half an interval
back in time until half an interval forward in time looking for the closest
timestamp to preserve.  In some cases, you may want a narrower or wider search
distance, and you can set C<reach_factor> accordingly.  You can also supply it
as another hash key for a retain rule for per-rule customization.

  retain => [
    { interval => { days => 1 }, duration => { days => 20 }, reach_factor => .75 }
  ]

=head2 time_zone

When date strings are involved, parse them as this time zone before converting
to an epoch value used in the calculations.  The default is C<'floating'>.

=head2 reach_factor

The multiplier for how far to look in each direction from an interval point.
See discussion in L</retain>.

=head2 reference_date

The end-point from which all intervals will be calculated.  There is no
default, to allow L</reference_date_or_default> to always pick up the current
time when called.

=head2 reference_date_or_default

Read-only.  Return (a clone of) L</reference_date>, or if it isn't set, return
the current date in the designated L</time_zone> rounded up to the next day
boundary.

=head2 auto_sync

While walking backward through time intervals looking for backups, adjust the
interval endpoint to be closer to whatever match it found.  This might allow
the algorithm to essentially adjust the C<reference_date> to match whatever
schedule your backups are running on.  This is not enabled by default.

=cut

has retain         => ( is => 'rw', required => 1 );
has time_zone      => ( is => 'rw', default => sub { 'floating' } );
has reach_factor   => ( is => 'rw', default => sub { .5 } );
has reference_date => ( is => 'rw' );
has auto_sync      => ( is => 'rw' );

sub reference_date_or_default {
	my $self= shift;
	# Use override, else 'now' rounded up to next day boundary of timezone
	my $start= $self->reference_date;
	return $start->clone if ref $start;
	return $self->_coerce_date($start) if defined $start;
	return DateTime->now(time_zone => $self->time_zone)
		 ->add(days => 1, seconds => -1)->truncate(to => 'day');
	return $start;
}

=head1 METHODS

=head1 prune

  my $pruned_arrayref= $self->prune( \@times );

C<@times> may be an array of epoch numbers, DateTime objects, or date strings
in any format recognized by L<DateTime::Format::Flexible>.  Epochs are
currently the most efficient type of argument since that's what the algorithm
operates on.

=cut

sub prune {
	my ($self, $list)= @_;
	my (@sorted, @retain, @prune);
	# Each list element needs to be a date object, (but preserve the original)
	# and the list needs to be sorted in cronological order.
	@sorted= sort { $a->[0] <=> $b->[0] }
		# tuple of [ Epoch, ListIndex, KeepBoolean ].
		# A hash would be more readable but there could be a lot of these.
		map [ $self->_coerce_to_epoch($list->[$_]), $_, 0 ],
			0..$#$list;
	# Set the boolean to true for each element that a rule wants to keep
	$self->_mark_for_retention($_->{interval}, $_->{duration}, $_->{reach_factor} // $self->reach_factor, \@sorted)
		for @{ $self->retain };
	# Then divide the elements into two lists.  Make a set of which indexes
	# we're keeping, then iterate the original list to preserve the caller's
	# list order.
	my %keep= map +($_->[1] => 1), grep $_->[2], @sorted;
	push @{ $keep{$_}? \@retain : \@prune }, $list->[$_]
		for 0..$#$list;
	@$list= @retain;
	return \@prune;
}

sub _coerce_date {
	my ($self, $thing)= @_;
	my $date= ref $thing && ref($thing)->can('set_time_zone')? $_->clone
		: looks_like_number($thing)? DateTime->from_epoch(epoch => $thing)
		: DateTime::Format::Flexible->parse_datetime($thing);
	$date->set_time_zone($self->time_zone);
	return $date;
}

sub _coerce_to_epoch {
	my ($self, $thing)= @_;
	return $thing if !ref $thing && looks_like_number($thing);
	return $self->_coerce_date($thing)->epoch;
}

sub _mark_for_retention {
	my ($self, $interval, $duration, $reach_factor, $list)= @_;
	my $next_date=   $self->reference_date_or_default;
	my $epoch=       $next_date->epoch;
	my $search_idx=  $#$list; # high value, iterates downward
	my $final_epoch= $next_date->clone->subtract(%$duration)->epoch;
	my $next_epoch=  $next_date->subtract(%$interval)->epoch;
	my $radius=      ($epoch - $next_epoch) / 2 * $reach_factor;
	my $drift=       0; # only used for auto_sync
	
	# Iterating backward accross date intervals and also input points, which is awkward.
	# The epoch variables track the current date interval, and the _idx
	# variables track our position in the list.
	while ($epoch > $final_epoch && $search_idx >= 0) {
		my $best;
		#printf STDERR "start_idx=%d goal=%s date range (%s..%s]\n",
		#	$start_idx, $self->_coerce_date($goal_epoch), $self->_coerce_date($limit_epoch-$radius), $self->_coerce_date($start_epoch+$radius);
		for (my $i= $search_idx; $i >= 0 and $list->[$i][0] > $epoch+$drift-$radius; --$i) {
			#printf STDERR "  i=%d list[i]=%s (%d)  best=%s\n",
			#	$i, $self->_coerce_date($list->[$i][0]), $list->[$i][0], ($best? $self->_coerce_date($best->[0]) : '-');
			if ($list->[$i][0] <= $epoch+$drift+$radius
				and (!$best or abs($list->[$i][0] - ($epoch+$drift)) < abs($best->[0] - ($epoch+$drift)))
			) {
				#print STDERR "   (best so far)\n";
				$best= $list->[$i];
			}
			# update the start_idx for next interval iteration
			$search_idx= $i-1 if $list->[$i][0] > $next_epoch+$drift+$radius;
		}
		if ($best) {
			$best->[2]= 1; # mark as a keeper
			# If option enabled, drift toward the time we found, so that gap between next
			# is closer to $interval
			$drift += ($best->[0] - ($epoch+$drift))/2
				if $self->auto_sync;
		}
		$epoch= $next_epoch;
		$next_epoch= $next_date->subtract(%$interval)->epoch;
		
		# if auto_sync enabled, cause drift to decay back toward 0
		$drift= int($drift * 7/8)
			if $drift;
	}
}

1;
