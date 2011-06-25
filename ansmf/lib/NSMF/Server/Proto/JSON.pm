package NSMF::Server::Proto::JSON;

use v5.10;
use strict;

use NSMF::Server;
use NSMF::Util;
use NSMF::Server::ModMngr;
use NSMF::Server::AuthMngr;
use NSMF::Server::ConfigMngr;
use NSMF::Common::Logger;

use POE;
use POE::Session;
use POE::Wheel::Run;
use POE::Filter::Reference;

use Date::Format;
use Data::Dumper;
use Compress::Zlib;
use MIME::Base64;

use JSON;

use constant {

  # JSONRPC defined errors
  JSONRPC_ERR_PARSE            => {
      code => -32700,
      message => 'Invalid JSON was received.'
  },
  JSONRPC_ERR_INVALID_REQUEST  => {
      code => -32600,
      message => 'The JSON sent is not a valid Request object.'
  },
  JSONRPC_ERR_METHOD_NOT_FOUND => {
      code => -32601,
      message => 'The method does not exist / is not available.'
  },
  JSONRPC_ERR_INVALID_PARAMS   => {
      code => -32602,
      message => 'Invalid method parameters.'
  },
  JSONRPC_ERR_INTERNAL         => {
      code => -32603,
      message => 'An internal error encountered.'
  },

  #
  # APPLICATION ERRORS
  #

  #
  # GENERAL
  JSONRPC_NSMF_BAD_REQUEST => {
    code => -1,
    message => 'BAD request.'
  },

  JSONRPC_NSMF_UNAUTHORIZED => {
    code => -2,
    message => 'Unauthorized.'
  },

  #
  # AUTH
  JSONRPC_NSMF_AUTH_UNSUPPORTED => {
    code => -10,
    message => 'AUTH unsupported.'
  },

  #
  # IDENT
  JSONRPC_NSMF_IDENT_UNSUPPORTED => {
    code => -20,
    message => 'IDENT unsupported.'
  },
};

#

our $VERSION = '0.1';

my $instance;
my $config = NSMF::Server::ConfigMngr->instance;
my $modules = $config->{modules} // [];
my $logger = NSMF::Common::Logger->new();

sub instance {
    return $instance if ( $instance );

    my ($class) = @_;
    return bless({}, $class);
}

sub states {
    my ($self) = @_;

    return if ( ref($self) ne 'NSMF::Server::Proto::JSON' );

    return [
        'dispatcher',
        'authenticate',
        'identify',
        'got_ping',
        'got_pong',
        'got_post',
        'send_ping',
        'send_pong',
        'send_error',
        'get',
        'child_output',
        'child_error',
        'child_signal',
        'child_close',
    ];
}

sub dispatcher {
    my ($kernel, $request) = @_[KERNEL, ARG0];

    my $json = {};

    eval {
        $json = decode_json(trim($request));
    };

    if ( $@ ) {
        $logger->error('Invalid JSON request: ' . $request);
        return;
    }

    if ( exists($json->{method}) )
    {
        my $action = $json->{method};

        given($json->{method}) {
            when(/authenticate/) { }
            when(/identify/) { }
            when(/ping/) {
                $action = 'got_ping';
            }
            when(/pong/) {
                $action = 'got_pong';
            }
            when(/post/i) {
                $action = 'got_post';
            }
            when(/get/i) {
                $action = 'get';
            }
            default: {
                $logger->debug(Dumper($json));
                $action = 'send_error';
            }
        }

        $kernel->yield($action, $json);
    }
}

sub authenticate {
    my ($kernel, $session, $heap, $json) = @_[KERNEL, SESSION, HEAP, ARG0];
    my $self = shift;

    $logger->debug( "  -> Authentication Request");

    eval {
        $self->jsonrpc_validate($json, ['$agent','$secret']);
    };

    if ( ref $@ ) {
      $logger->error('Incomplete JSON AUTH request. ' . $@->{message});
      $heap->{client}->put($@->{object});
      return;
    }

    my $agent  = $json->{params}{agent};
    my $secret = $json->{params}{secret};

    eval {
        NSMF::Server::AuthMngr->authenticate($agent, $secret);
    };

    if ($@) {
        $logger->error('    = Not Found ' .$@);
        $heap->{client}->put($self->json_error_create($json, JSONRPC_NSMF_AUTH_UNSUPPORTED));
        return;
    }

    $heap->{agent}    = $agent;
    $logger->debug("    [+] Agent authenticated: $agent"); 

    $heap->{client}->put($self->json_result_create($json, ''));
}

sub identify {
    my ($kernel, $session, $heap, $json) = @_[KERNEL, SESSION, HEAP, ARG0];
    my $self = shift;

    eval {
        $self->jsonrpc_validate($json, ['$module','$netgroup']);
    };

    if ( ref $@ ) {
      $logger->error('Incomplete JSON ID request. ' . $@->{message});
      $heap->{client}->put($@->{object});
      return;
    }

    my $module = trim(lc($json->{params}{module}));
    my $netgroup = trim(lc($json->{params}{netgroup}));

    if ($heap->{session_id}) {
        $logger->warn( "$module is already authenticated");
        return;
    }

    if ($module ~~ @$modules) {

        $logger->debug("    ->  " .uc($module). " supported!"); 

        $heap->{module_name} = $module;
        $heap->{session_id} = 1;
        $heap->{status}     = 'EST';

        eval {
            $heap->{module} = NSMF::Server::ModMngr->load(uc $module);
        };

        if ($@) {
            $logger->error("    [FAILED] Could not load module: $module");
            $logger->debug($@);
        }

        $heap->{session_id} = $_[SESSION]->ID;

        if (defined $heap->{module}) {
            # $logger->debug("Session Id: " .$heap->{session_id});
            # $logger->debug("Calilng Hello World Again in the already defined module");
            $logger->debug("      ----> Module Call <----");
            $heap->{client}->put($self->json_result_create($json, 'ID accepted'));
            return;
            my $child = POE::Wheel::Run->new(
                Program => sub { $heap->{module}->run  },
                StdoutFilter => POE::Filter::Reference->new(),
                StdoutEvent => "child_output",
                StderrEvent => "child_error",
                CloseEvent  => "child_close",
            );

            $kernel->sig_child($child->PID, "child_signal");
            $heap->{children_by_wid}{$child->ID} = $child;
            $heap->{children_by_pid}{$child->PID} = $child;
        }
    }
    else {
        $heap->{client}->put($self->json_error_create($json, JSONRPC_NSMF_IDENT_UNSUPPORTED));
    }

}

sub got_pong {
    my ($kernel, $heap, $json) = @_[KERNEL, HEAP, ARG0];
    my $self = shift;

    $logger->debug("  <- Got PONG"); 
}

sub got_ping {
    my ($kernel, $heap, $json) = @_[KERNEL, HEAP, ARG0];
    my $self = shift;

    eval {
        $self->jsonrpc_validate($json, ['$timestamp']);
    };

    if ( ref $@ ) {
      $logger->error('Incomplete PING request. ' . $@->{message});
      $heap->{client}->put($@->{object});
      return;
    }

    my $ping_time = $json->{params}{timestamp};

    $heap->{ping_recv} = $ping_time if $ping_time;

    if ( $heap->{status} ne 'EST' || ! $heap->{session_id}) {
        $heap->{client}->put($self->json_error_create($json, JSONRPC_NSMF_UNAUTHORIZED));
        return;
    }

    $logger->debug("  <- Got PING");
    $kernel->yield('send_pong', $json);
}

sub child_output {
    my ($kernel, $heap, $output) = @_[KERNEL, HEAP, ARG0];
    $logger->debug(Dumper($output));
}

sub child_error {
    $logger->error("Child Error: $_[ARG0]");
}

sub child_signal {
    my $heap = $_[HEAP];
    #$logger->debug("   * PID: $_[ARG1] exited with status $_[ARG2]");
    my $child = delete $heap->{children_by_pid}{$_[ARG1]};

    return if ( ! defined($child) );

    delete $heap->{children_by_wid}{$child->ID};
}

sub child_close {
    my ($heap, $wid) = @_[HEAP, ARG0];
    my $child = delete $heap->{children_by_wid}{$wid};

    if ( ! defined($child) ) {
    #    $logger->debug("Wheel Id: $wid closed");
        return;
    }

    #$logger->debug("   * PID: " .$child->PID. " closed");
    delete $heap->{children_by_pid}{$child->PID};
}

sub got_post {
    my ($kernel, $heap, $json) = @_[KERNEL, HEAP, ARG0];
    my $self = shift;

    if ( $heap->{status} ne 'EST' || ! $heap->{session_id}) {
        $heap->{client}->put($self->json_result_create($json, 'Bad request'));
        return;
    }

    eval {
        my ($ret, $response) = $self->jsonrpc_validate($json, ['$type', '$jobid', '%data']);
    };

    if ( ref $@ ) {
      $logger->error('Incomplete POST request. ' . $@->{message});
      $heap->{client}->put($@->{object});
      return;
    }

    $logger->debug(' -> This is a post for ' . $heap->{module_name});
    $logger->debug('    - Type: '. $json->{params}{type});
    $logger->debug('    - Job Id: ' . $json->{params}{job_id});

    my $module = $heap->{module};
    $module->validate( $json->{params} );
    $module->save( $json->{params} ) or $logger->error($module->errstr);

    # need to reply here
    $logger->debug("    Session saved");
}

sub send_ping {
    my ($kernel, $heap, $request) = @_[KERNEL, HEAP, ARG0];
    my $self = shift;

    $logger->debug('  -> Sending PING');
    my $payload = "PING " .time. " NSMF/1.0\r\n";
    $heap->{client}->put($payload);
}

sub send_pong {
    my ($kernel, $heap, $json) = @_[KERNEL, HEAP, ARG0];
    my $self = shift;

    $logger->debug('  -> Sending PONG');

    my $response = $self->json_result_create($json, {
        "timestamp" => time()
    });

    $heap->{client}->put($response);
}

sub send_error {
    my ($kernel, $heap, $json) = @_[KERNEL, HEAP, ARG0];
    my $self = shift;

    warn "[!] BAD REQUEST" if $NSMF::Server::DEBUG;
    $heap->{client}->put($self->json_error_create($json, JSONRPC_NSMF_BAD_REQUEST));
}

sub get {
    my ($kernel, $heap, $json) = @_[KERNEL, HEAP, ARG0];
    my $self = shift;

    if ( $heap->{status} ne 'EST' || ! $heap->{session_id}) {
        $heap->{client}->put($self->json_error_create($json, JSONRPC_NSMF_BAD_REQUEST));
        return;
    }

    eval {
       my ($ret, $response) = $self->jsonrpc_validate($json, ['$type', '$jobid', '%data']);
    };

    if ( ref $@ ) {
      $logger->error('Incomplete GET request. ' . $@->{message});
      $heap->{client}->put($@->{object});
      return;
    }

    # search data
    my $payload = encode_base64( compress( 'A'x1000 ) );
    $heap->{client}->put($self->json_result_create($json, $payload));
}

#
# PRIVATES
#

# TODO: move to a dedicated lib
# function will modifiy JSON object in place
# function will raise exception via 'die' perhaps should be 'warn' on invalidation
# key lookup (need to change)
# wrap in eval {}
#      $ (scalar)
#      @ (array)
#      % (object)
#
sub jsonrpc_validate
{
    my ($self, $json, $mandatory, $optional) = @_;

    my $type_map = {
        '%' => "HASH",
        '@' => "ARRAY",
        '$' => "",
        "#" => "HASH",
        "*" => "ARRAY",
        "+" => "SCALAR",
        "." => ""
    };

    if ( ! exists($json->{"params"}) )
    {
        die {
            status => 'error',
            message => 'No params defined.',
            object => $self->json_error_create($json, JSONRPC_ERR_INVALID_PARAMS)
        };
    }
    elsif ( ref($json->{"params"}) eq "HASH" )
    {
        # check all mandatory arguments
        for my $arg ( @{ $mandatory } )
        {
            my $type = substr($arg, 0, 1);
            my $param = substr($arg, 1);

            if ( ! defined($json->{"params"}{$param}) )
            {
                die {
                    status => 'error',
                    message => 'Mandatory param"' . $param . '" not found.',
                    object => $self->json_error_create($json, JSONRPC_ERR_INVALID_PARAMS)
                };
            }
            elsif ( ref($json->{"params"}{$param}) ne $type_map->{$type} )
            {
                die {
                    status => 'error',
                    message => 'Some params are not of the correct type. Expected "' . $param . '" to be of type "' .$type_map->{$type}. '". Got "' .ref( $json->{params}{$param} ). '"',
                    object => $self->json_error_create($json, JSONRPC_ERR_INVALID_PARAMS)
                };
            };
        }
    }
    elsif ( ref($json->{"params"}) eq "ARRAY" )
    {
        my $params_by_name = {};

        # check all mandatory arguments
        for my $arg ( @{ $mandatory } )
        {
            my $type = substr($arg, 0, 1);
            my $param = substr($arg, 1);

            # check we have parameters still on the list
            if ( @{ $json->{"params"} } )
            {
                if ( ref( @{ $json->{"params"} }[0]) eq $type_map->{$type} )
                {
                    $params_by_name->{$param} = shift( @{$json->{"params"}} );
                }
                else
                {
                    die {
                        status => 'error',
                        message => 'Some params are not of the correct type. Expected "' . $param . '" to be of type "' .$type_map->{$type}. '". Got "' .ref( @{$json->{params}}[0] ). '"',
                        object => $self->json_error_create($json, JSONRPC_ERR_INVALID_PARAMS)
                    };
                }
            }
            else
            {
                die {
                    status => 'error',
                    message => 'Some params are not of the correct type. Expected "' . $param . '" to be of type "' .$type_map->{$type}. '". Got "' .ref( @{$json->{params}}[0] ). '"',
                    object => $self->json_error_create($json, JSONRPC_ERR_INVALID_PARAMS)
                };
            }
        }

        # check all optional arguments
        for my $arg ( @{ $optional } )
        {
            my $type = substr($arg, 0, 1);
            my $param = substr($arg, 1);

            # check we have parameters still on the list
            if ( @{ $json->{"params"} } )
            {
                if ( ref( @{ $json->{"params"} }[0]) eq $type_map->{$type} )
                {
                    $params_by_name->{$param} = shift( @{$json->{"params"}} );
                }
                else
                {
                    die {
                        status => 'error',
                        message => 'Some params are not of the correct type. Expected "' . $param . '" to be of type "' .$type_map->{$type}. '". Got "' .ref( @{$json->{params}}[0] ). '"',
                        object => $self->json_error_create($json, JSONRPC_ERR_INVALID_PARAMS)
                    };
                };
            }
            else
            {
                last;
            }
        }

        # replace by-position parameters with by-name
        $json->{"params"} = $params_by_name;
    }
    else
    {
        die {
            status => 'error',
            message => 'Specified params corrupted or of unknown type.',
            object => $self->json_error_create($json, JSONRPC_ERR_INVALID_PARAMS)
        };
    }
}

sub json_response_create
{
  my ($self, $type, $json, $data) = @_;

  # no response should occur if not of type result or error
  return "" if ( ! ($type ~~ ["result", "error"]) );

  # no response should occur if no id was specified (ie. notification)
  return "" if ( ! defined($json) || ! exists($json->{id}) );

  my $result = {};

  $result->{id} = $json->{id};
  $result->{$type} = $data // {};

  return encode_json($result);
}

sub json_result_create
{
  my ($self, $json, $data) = @_;

  return $self->json_response_create("result", $json, $data);
}

sub json_error_create
{
  my ($self, $json, $data) = @_;

  return $self->json_response_create("error", $json, $data);
}

1;

