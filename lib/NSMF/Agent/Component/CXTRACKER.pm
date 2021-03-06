#
# This file is part of the NSM framework
#
# Copyright (C) 2010-2011, Edward Fjellskål <edwardfjellskaal@gmail.com>
#                          Eduardo Urias    <windkaiser@gmail.com>
#                          Ian Firns        <firnsy@securixlive.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License Version 2 as
# published by the Free Software Foundation.  You may not use, modify or
# distribute this program under any other version of the GNU General
# Public License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
#
package NSMF::Agent::Component::CXTRACKER;

use warnings;
use strict;
use v5.10;

use base qw(NSMF::Agent::Component);

#
# PERL INCLUDES
#
use Data::Dumper;
use Carp;
use POE;

#
# NSMF INCLUDES
#
use NSMF::Common::Util;

use NSMF::Agent;
use NSMF::Agent::Action;

#
# CONSTATS
#
our $VERSION = {
  major    => 0,
  minor    => 1,
  revision => 0,
  build    => 2,
};


#
# IMPLEMENTATION
#

sub type {
    return "CXTRACKER";
}

sub hello {
    my ($self) = shift;
    $self->logger->debug('   Hello from CXTRACKER Node!!');
}

sub sync {
    my $self = shift;

    $self->SUPER::sync();
    my $settings = $self->{__config}->settings();

    $self->logger->error('CXTDIR undefined!') unless $settings->{cxtdir};

    $self->{watcher} = NSMF::Agent::Action->file_watcher({
        directory => $settings->{cxtdir},
        callback  => [ $self, '_process' ],
        interval  => 3,
        pattern   => 'stats\..+\.(\d){10}'
    });
}

sub run {
    my ($kernel, $heap) = @_[KERNEL, HEAP];
    my $self = shift;

    $self->logger->debug("Running cxtracker processing..");

    $self->hello();
}


sub _process {
    my ($kernel, $heap, $file) = @_[KERNEL, HEAP, ARG0];
    my $self = shift;

    # there is no point sending if we're not connected to the server
    my $connected =  $kernel->call('node', 'connected') // 0;

    if( $connected == 0 ) {
        return;
    }

    # we need a valid node_id to mark identify all our communications
    $heap->{node_id} //= -1;

    if ( $heap->{node_id} < 0 ) {
        $heap->{node_id} = $kernel->call('node', 'get', 'get_node_id');
        return;
    }

    return unless defined $file;

    if ( ! ( -r -w -f $file ) )
    {
        $self->logger->info('Insufficient permissions to operate on file: ' . $file);
        return;
    };

    $self->logger->info("Found file: $file");

    my ($sessions, $start_time, $end_time, $process_time, $result);

    $start_time   = time();
    $sessions     = _get_sessions($file, $heap->{node_id});
    $end_time     = time();
    $process_time = $end_time - $start_time;
    $self->logger->debug("File $file processed in $process_time seconds");
    $start_time   = $end_time;

    if ( @{ $sessions } ) {
        for my $session ( @{ $sessions } )
        {
            $kernel->post('node', 'post', $session);
        }
        $end_time     = time();
        $process_time = $end_time - $start_time;

        $self->logger->debug("Session record(s) sent in $process_time seconds");
    }

    unlink($file) or $self->logger->error("Failed to delete: $file");
}

=head2 _get_sessions

 This sub extracts the session data from a session data file.
 Takes $file as input parameter.

=cut

sub _get_sessions {
    my ($sfile, $node_id) = @_;
    my $sessions_data = [];

    my $logger = NSMF::Common::Registry->get('log');
    $logger->debug('Session file found: ' . $sfile);

    if ( open(FILE, $sfile) ) {
        my $cnt = 0;
        # verify the data in the session files
        while (my $line = readline FILE) {
            chomp $line;
            $line =~ /^\d{19}/;
            unless($line) {
                $logger->error("Not valid session start format in: '$sfile'");
                next;
            }

            my @elements = split(/\|/, $line);

            unless(@elements == 15) {
                $logger->error("Not valid number of session args format in: '$sfile'");
                next;
            }

            # build the session structs
            push( @{ $sessions_data }, {
                id => $elements[0],
                timestamp => 0,
                time_start => $elements[1],
                time_end   => $elements[2],
                time_duration => $elements[3],
                node_id => $node_id,
                net_version => 4,
                net_protocol => $elements[4],
                net_src_ip   => $elements[5],
                net_src_port => $elements[6],
                net_src_total_packets => $elements[9],
                net_src_total_bytes => $elements[10],
                net_src_flags => $elements[13],
                net_dst_ip   => $elements[7],
                net_dst_port => $elements[8],
                net_dst_total_packets => $elements[11],
                net_dst_total_bytes => $elements[12],
                net_dst_flags => $elements[14],
                data_filename => 'filename.ext',
                data_offset => 0,
                data_length => 0,
                meta_cxt_id => $elements[0],
            });
        }

        close FILE;

        return $sessions_data;
    }
}

1;
