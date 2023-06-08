#!/usr/bin/perl

use warnings;
use strict;
use Data::Dumper qw/Dumper/;

open(my $fh, "< $ARGV[0]") or die "can't open: $@";
my $offset = $ARGV[1] || -1;

my $test = '';
my %stats = ();
my %stats_count = ();
my %timers = ();
my $main_test = '';
my $next_test = '';
# FIXME: remove this once the main data is fixed.
my $skip_timer = 0;

my @tests = ();

my $cur_test = '';
my $cur_st = '';
while (my $line = <$fh>) {
    if ($line =~ m/^\+\+\+ test (\S+) \+\+\+/) {
        $cur_test = {name => $1, st => []};
        push(@tests, $cur_test);
    } elsif ($line =~ m/^\+\+\+\s+(.*)\s+\+\+\+$/) {
        $cur_st = {name => $1, stats => {}, statsc => {}, timers => {}};
        push(@{$cur_test->{st}}, $cur_st);
        $skip_timer = 1;
    } elsif ($line =~ m/^stat:\s+(\S+)\s+:\s+(\d+)/) {
        my $s = $1;
        my $n = $2;
        $cur_st->{stats}->{$s} += $n;
        $cur_st->{statsc}->{$s}++;
    } elsif ($line =~ m/^=== timer (\S+) ===/) {
        parse_timers($1, $cur_st->{timers}, $fh);
        if ($skip_timer) {
            # FIXME: REMOVE THIS ONCE FIXED UPSTREAM.
            $cur_st->{timers} = {};
            %timers = ();
            $skip_timer = 0;
        }
    }
}

for my $t (@tests) {
    print("======= TEST ", $t->{name}, " =======\n");
    if ($offset != -1) {
        my $st = $t->{st}->[$offset];
        display_test($st);
    } else {
        for my $st (@{$t->{st}}) {
            display_test($st);
        }
    }
}

#print Dumper(\@tests), "\n";

print("done\n");

sub display_test {
    my $st = shift;
    print("--- subtest ", $st->{name}, " ---\n");
    for my $key (sort keys %{$st->{stats}}) {
        print("stat: $key : ", int($st->{stats}->{$key} / $st->{statsc}->{$key}), "\n");
    }
    for my $cmd (sort keys %{$st->{timers}}) {
        my $s = $st->{timers}->{$cmd};
        my $us = $s->{us};
        my $ms = $s->{ms};

        # total the counts.
        my $sum = 0;
        for (0..2) {
            $sum += $us->[$_];
        }
        for my $n (@{$ms}) {
            $sum += $n if defined $n;
        }
        $sum += $s->{oob};

        print("=== timer $cmd ===\n");
        printf "1us\t%d\t%.3f%%\n", $us->[0], $us->[0] / $sum * 100;
        printf "10us\t%d\t%.3f%%\n", $us->[1], $us->[1] / $sum * 100;
        printf "100us\t%d\t%.3f%%\n", $us->[2], $us->[2] / $sum * 100;

        for (1..100) {
            if (defined $ms->[$_]) {
                printf "%dms\t%d\t%.5f%%\n", $_, $ms->[$_], $ms->[$_] / $sum * 100;
            }
        }
        if ($s->{oob}) {
            printf "100ms+\t%d\t%.5f%%\n", $s->{oob}, $s->{oob} / $sum * 100;
        }
    }
}

sub parse_timers {
    my $n = shift;
    my $h = shift;
    my $fh = shift;
    if (! defined $h->{$n}) {
        $h->{$n} = { us => [0, 0, 0], ms => [], oob => 0 };
    }
    my $s = $h->{$n};

    while (my $line = <$fh>) {
        if ($line =~ m/=== end ===/) {
            last;
        }
        if ($line =~ m/(\d+)us\s+(\d+)/) {
            my $b = $1;
            my $cnt = $2;
            if ($b eq "1") { $s->{us}->[0] += $cnt }
            if ($b eq "10") { $s->{us}->[1] += $cnt }
            if ($b eq "100") { $s->{us}->[2] += $cnt }
        } elsif ($line =~ m/(\d+)ms\s+(\d+)/) {
            $s->{ms}->[$1] += $2;
        } elsif ($line =~ m/^100ms\+:\s+(\d+)/) {
            $s->{oob} += $1;
        }
    }
}
