#!/usr/bin/perl
use strict;
use warnings;
use autodie;

use Getopt::Long qw(HelpMessage);
use FindBin;
use YAML::Syck qw(Dump Load DumpFile LoadFile);

use File::Basename;
use Graph;
use List::MoreUtils qw(uniq);

use AlignDB::IntSpan;
use AlignDB::Stopwatch;

use lib "$FindBin::RealBin/lib";
use MyUtil qw(string_to_set);

#----------------------------------------------------------#
# GetOpt section
#----------------------------------------------------------#

=head1 NAME

merge_node.pl - merge overlapped nodes of paralog graph
    
=head1 SYNOPSIS

    perl merge_node.pl -f <file> [options]
      Options:
        --help          -?          brief help message
        --file          -f  STR     file
        --output        -o  STR     output   
        --coverage      -c  FLOAT   When larger than this ratio, merge nodes, default is [0.9]       
        --verbose       -v          verbose mode

=cut

GetOptions(
    'help|?'     => sub { HelpMessage(0) },
    'files|f=s'  => \my @files,
    'output|o=s' => \my $output,
    'coverage|c=f' => \( my $coverage = 0.9 ),
    'v|verbose|v' => \my $verbose,
) or HelpMessage(1);

if ( !$output ) {
    $output = basename( $files[0] );
    ($output) = grep {defined} split /\./, $output;
    $output = "$output.merge.yml";
}

#----------------------------------------------------------#
# Init
#----------------------------------------------------------#
my $stopwatch = AlignDB::Stopwatch->new;
$stopwatch->start_message("Paralog graph");

#----------------------------------------------------------#
# Start
#----------------------------------------------------------#

#----------------------------#
# Read
#----------------------------#
my $g = Graph->new( directed => 0 );
my %chrs;

# nodes are in "chr1:50-100" form, and with attributes of chr name and
# intspan object
for my $file (@files) {
    open my $in_fh, "<", $file;
    while ( my $line = <$in_fh> ) {
        chomp $line;

        my @nodes = ( split /\t/, $line )[ 0, 1 ];
        for my $node (@nodes) {
            if ( !$g->has_vertex($node) ) {
                $g->add_vertex($node);
                my ( $chr, $set, $strand ) = string_to_set($node);
                $g->set_vertex_attribute( $node, "chr",    $chr );
                $g->set_vertex_attribute( $node, "set",    $set );
                $g->set_vertex_attribute( $node, "strand", $strand );

                $chrs{$chr}++;
                print "Add node $node\n";
            }
        }
    }
    $stopwatch->block_message("Finish loading [$file]");
}

#----------------------------#
# Merge
#----------------------------#
$stopwatch->block_message("Merge nodes");

for my $chr ( sort keys %chrs ) {
    print "Merge nodes in chromosome [$chr]\n";
    my @nodes = sort grep { $g->get_vertex_attribute( $_, "chr" ) eq $chr } $g->vertices;

    for my $i ( 0 .. $#nodes ) {
        my $node_i = $nodes[$i];
        print " " x 4, "Node $i / @{[$#nodes]}\t$node_i\n";
        my $set_i = $g->get_vertex_attribute( $node_i, "set" );
        for my $j ( $i + 1 .. $#nodes ) {
            my $node_j = $nodes[$j];
            my $set_j = $g->get_vertex_attribute( $node_j, "set" );

            my $i_set = $set_i->intersect($set_j);
            if ( $i_set->is_not_empty ) {
                my $coverage_i = $i_set->size / $set_i->size;
                my $coverage_j = $i_set->size / $set_j->size;
                if (    $coverage_i >= $coverage
                    and $coverage_j >= $coverage )
                {
                    $g->add_edge( $nodes[$i], $nodes[$j] );
                    print " " x 8, "Merge with Node $j / @{[$#nodes]}\t$node_j\n";
                }
            }
        }
    }
}

#----------------------------#
# Hash of merge
#----------------------------#
$stopwatch->block_message("Output merged");
my $merged_of = {};
{
    my @cc = $g->connected_components;

    # filter single nodes
    @cc = grep { scalar @{$_} > 1 } @cc;

    for my $c (@cc) {
        print "\n";
        my $chr = $g->get_vertex_attribute( $c->[0], "chr" );
        my $merge_set = AlignDB::IntSpan->new;
        my @strands;
        my ( $strand, $change );
        for my $node ( @{$c} ) {
            my $set = $g->get_vertex_attribute( $node, "set" );
            $merge_set->add($set);
            push @strands, $g->get_vertex_attribute( $node, "strand" );
        }
        @strands = uniq(@strands);
        if ( @strands == 1 ) {
            print " " x 4, "All nodes have the same strand\n";
            $strand = $strands[0];
            $change = 0;
        }
        else {
            print " " x 4, "Nodes have different strands\n";
            $strand = "+";
            $change = 1;
        }
        my $merge_node = "$chr($strand):" . $merge_set->runlist;

        for my $node ( @{$c} ) {
            my $node_change = 0;
            if ($change) {
                $node =~ /\(.\)/;
                my $node_strand = $1;
                if ( $node_strand ne $strand ) {
                    $node_change = 1;
                }
            }
            $merged_of->{$node} = { node => $merge_node, change => $node_change };
            print "$node => $merge_node\n";
        }
    }

    DumpFile( $output, $merged_of );
}

$stopwatch->end_message;
exit;

__END__
