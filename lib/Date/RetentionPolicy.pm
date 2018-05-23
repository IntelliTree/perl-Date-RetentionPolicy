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

=cut

has retain         => ( is => 'rw', required => 1 );
has time_zone      => ( is => 'rw', default => sub { 'floating' } );
has reach_factor   => ( is => 'rw', default => sub { .45 } );
has reference_date => ( is => 'rw' );
has auto_sync      => ( is => 'rw' );

sub reference_date_or_default {
	my $self= shift;
	# Use override, else 'now' rounded up to next day boundary of timezone
	my $start= $self->reference_date;
	$start= !$start? DateTime->now(time_zone => $self->time_zone)->add(days => 1)->truncate(to => 'day')
		: ref $start? $start->clone
		: $self->_coerce_date($start);
	return $start;
}

sub prune {
	my ($self, $list)= @_;
	my (@sorted, @retain, @prune);
	# Each list element needs to be a date object, (but preserve the original)
	# and the list needs to be sorted in cronological order.
	@sorted= sort { $a->[0] <=> $b->[0] }
		map [ $self->_coerce_to_epoch($list->[$_]), $_, 0 ],
			0..$#$list;
	# Record a boolean 'true' for each array index that a rule wants to keep
	$self->_mark_for_retention($_->{interval}, $_->{duration}, \@sorted)
		for @{ $self->retain };
	# Then divide the elements into two lists.  Move the keep list to a hash and
	# then iterate the original list to preserve the caller's list order.
	my %keep= map +($_->[1] => $_->[2]), @sorted;
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
	my ($self, $interval, $duration, $list)= @_;
	my $next_date=   $self->reference_date_or_default;
	my $start_epoch= $next_date->epoch;
	my $start_idx= $#$list;
	my $final_epoch= $next_date->clone->subtract(%$duration)->epoch;
	my $limit_epoch= $next_date->subtract(%$interval)->epoch;
	my $reach_radius= ($start_epoch - $limit_epoch) / 2 * $self->reach_factor;
	my $goal_epoch=  int(($start_epoch + $limit_epoch)/2);
	
	# Iterating backward accross date intervals and also input points, which is awkward.
	# The epoch variables track the current date interval, and the _idx
	# variables track our position in the list.
	while ($start_epoch > $final_epoch && $start_idx >= 0) {
		my $best;
		#printf STDERR "start_idx=%d goal=%s date range (%s..%s]\n",
		#	$start_idx, $self->_coerce_date($goal_epoch), $self->_coerce_date($limit_epoch-$reach_radius), $self->_coerce_date($start_epoch+$reach_radius);
		for (my $i= $start_idx; $i >= 0 and $list->[$i][0] > $limit_epoch-$reach_radius; --$i) {
			#printf STDERR "  i=%d list[i]=%s (%d)  best=%s\n",
			#	$i, $self->_coerce_date($list->[$i][0]), $list->[$i][0], ($best? $self->_coerce_date($best->[0]) : '-');
			if ($list->[$i][0] <= $start_epoch+$reach_radius
				and (!$best or abs($list->[$i][0] - $goal_epoch) < abs($best->[0] - $goal_epoch))
			) {
				#print STDERR "   (best so far)\n";
				$best= $list->[$i];
			}
			# update the start_idx for next interval iteration
			$start_idx= $i-1 if $list->[$i][0] > $limit_epoch+$reach_radius;
		}
		if ($best) {
			$best->[2]= 1; # mark as a keeper
			# If option enabled, move goal toward the time we found, so that gap between next
			# is closer to $interval
			$goal_epoch= ($goal_epoch + $best->[0])/2
				if $self->auto_sync;
		}
		$goal_epoch -= $start_epoch - $limit_epoch;
		$start_epoch= $limit_epoch;
		$limit_epoch= $next_date->subtract(%$interval)->epoch;
		
		# if auto_sync, and we moved the goal, cause goal to drift back toawrd middle
		$goal_epoch= int(($start_epoch + $limit_epoch + $goal_epoch*3)/5)
			if $self->auto_sync;
	}
}

1;
