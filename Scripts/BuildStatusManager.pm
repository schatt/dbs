package BuildStatusManager;

use strict;
use warnings;
use Carp;
use BuildUtils qw(log_debug);  # Import log_debug function
use BuildUtils qw(is_successful_completion_status);

sub new {
    my ($class) = @_;
    my $self = {
        status   => {}, # key => status string
        duration => {}, # key => seconds
        actually_executed => {}, # key => 1 if executed, 0 if skipped
        breadcrumbs => {}, # key => array of status transitions with timestamps
        execution_order => [], # chronological order of nodes becoming ready
        build_start_time => time(), # when the build started
    };
    bless $self, $class;
    return $self;
}

sub new_with_initialization {
    my ($class, $registry) = @_;
    my $self = $class->new;
    $self->initialize_all_nodes($registry);
    return $self;
}

sub set_status {
    my ($self, $node, $status, $invocation_id) = @_;
    $invocation_id //= 1;
    # Store by stable identifier (name + args) instead of volatile key (includes refaddr)
    my $stable_key = $self->_generate_stable_key($node);
    
    # Get previous status for comparison
    my $previous_status = $self->{status}{$stable_key}{$invocation_id};
    
    # Update the status
    $self->{status}{$stable_key}{$invocation_id} = $status;
    
    # Add breadcrumb if status changed
    if (!defined($previous_status) || $previous_status ne $status) {
        # Determine phase based on status
        my $phase = $self->_determine_phase_from_status($status);
        $self->add_breadcrumb($node, $status, $phase, $invocation_id);
    }
}

sub get_status {
    my ($self, $node, $invocation_id) = @_;
    $invocation_id //= 1;
    
    # Debug what we're looking up (disabled to avoid issues with unblessed references)
    if (0 && $BuildUtils::VERBOSITY_LEVEL >= 3) {
        log_debug("BuildStatusManager::get_status: Looking up status for node: " . $node->name);
        log_debug("BuildStatusManager::get_status: Node input: " . ref($node) . " (ref: " . ref($node) . ")");
        log_debug("BuildStatusManager::get_status: Invocation ID: $invocation_id");
    }
    
    # Use same stable identifier logic as set_status
    my $stable_key = $self->_generate_stable_key($node);
    
    unless (defined $self->{status}{$stable_key} && defined $self->{status}{$stable_key}{$invocation_id}) {
        croak("Node '" . $node->name . "' has no status - this indicates an initialization bug. All nodes should be initialized with status before get_status is called.");
    }
    
    my $stored_status = $self->{status}{$stable_key}{$invocation_id};
    
    # Debug what we're returning (disabled to avoid issues with unblessed references)
    if (0 && $BuildUtils::VERBOSITY_LEVEL >= 3) {
        log_debug("BuildStatusManager::get_status: Stored status: '$stored_status' (ref: " . ref($stored_status) . ")");
        log_debug("BuildStatusManager::get_status: Returning: '$stored_status'");
    }
    
    return $stored_status;
}

sub get_all_statuses {
    my ($self, $invocation_id) = @_;
    $invocation_id //= 1;
    
    my %all_statuses;
    # Now that we're using node keys (strings) as hash keys, we can iterate normally
    for my $node_key (keys %{$self->{status}}) {
        if (defined $self->{status}{$node_key}{$invocation_id}) {
            # Use the node key as the return hash key (this is the original node->key value)
            $all_statuses{$node_key} = $self->{status}{$node_key}{$invocation_id};
        }
    }
    
    return \%all_statuses;
}

sub set_duration {
    my ($self, $node, $duration, $invocation_id) = @_;
    $invocation_id //= 1;
    # Store by node key (string) as hash key, with invocation_id as sub-key
    my $node_key = $node->key;
    $self->{duration}{$node_key}{$invocation_id} = $duration;
}

sub get_duration {
    my ($self, $node, $invocation_id) = @_;
    $invocation_id //= 1;
    # Look up by node key (string) as hash key, with invocation_id as sub-key
    my $node_key = $node->key;
    return $self->{duration}{$node_key}{$invocation_id};
}

# Helper methods for status checking
sub did_run {
    my ($self, $node, $invocation_id) = @_;
    $invocation_id //= 1;
    # Look up by node key (string) as hash key, with invocation_id as sub-key
    my $node_key = $node->key;
    return $self->{actually_executed}{$node_key}{$invocation_id} // 0;
}

sub did_succeed {
    my ($self, $node, $invocation_id) = @_;
    my $status = $self->get_status($node, $invocation_id);
    # Use centralized success status check for DRY principle
    # Note: This function is called from build.pl which has is_successful_completion_status
    # For now, maintain backward compatibility with explicit status checks
    return defined($status) && ($status eq 'done' || $status eq 'skipped' || $status eq 'dry-run' || $status eq 'validate');
}

sub did_fail {
    my ($self, $node, $invocation_id) = @_;
    my $status = $self->get_status($node, $invocation_id);
    return defined($status) && $status eq 'failed';
}

sub is_done {
    my ($self, $node, $invocation_id) = @_;
    return $self->did_succeed($node, $invocation_id);
}

sub is_skipped {
    my ($self, $node, $invocation_id) = @_;
    my $status = $self->get_status($node, $invocation_id);
    return defined($status) && $status eq 'skipped';
}

sub is_running {
    my ($self, $node, $invocation_id) = @_;
    my $status = $self->get_status($node, $invocation_id);
    return defined($status) && $status eq 'running';
}

sub is_pending {
    my ($self, $node, $invocation_id) = @_;
    my $status = $self->get_status($node, $invocation_id);
    return defined($status) && $status eq 'pending';
}

# Helper method to check if a status is valid for coordination (ready to be processed)
# This can be used by both BuildStatusManager and BuildNode for DRY principle
sub is_coordination_eligible_status {
    my ($self, $node) = @_;
    
    # Get status from this status manager using the node reference
    my $status = $self->get_status($node);
    
    # Debug the input and processing
    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
        log_debug("BuildStatusManager::is_coordination_eligible_status: Node: " . $node->name . ", Status: '$status' (ref: " . ref($status) . ")");
    }
    
    # 'coordinate' status means the node is already in coordination phase
    my $result = $status eq 'pending' || $status eq 'not_processed' || $status eq 'coordinate';
    
    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
        log_debug("BuildStatusManager::is_coordination_eligible_status: Comparison result = $result");
        log_debug("BuildStatusManager::is_coordination_eligible_status: '$status' eq 'pending' = " . ($status eq 'pending' ? 'true' : 'false'));
        log_debug("BuildStatusManager::is_coordination_eligible_status: '$status' eq 'not_processed' = " . ($status eq 'not_processed' ? 'true' : 'false'));
        log_debug("BuildStatusManager::is_coordination_eligible_status: '$status' eq 'coordinate' = " . ($status eq 'coordinate' ? 'true' : 'false'));
    }
    
    return $result;
}

# Helper method to check if a status is blocking (not ready for execution)
# This can be used by both BuildStatusManager and BuildNode for DRY principle
sub is_blocking_status {
    my ($self, $node) = @_;
    my $status = $self->get_status($node);
    # 'coordinate' status is NOT blocking - node is ready for next phase
    return $status eq 'pending' || $status eq 'in-progress';
}

# Helper method to check if a node is in coordination phase (ready for next phase)
sub is_coordination_status {
    my ($self, $node) = @_;
    my $status = $self->get_status($node);
    return $status eq 'coordinate';
}

# This includes done, skipped, validate (dry-run validation), and dry-run modes
# Note: is_successful_completion_status is now imported from BuildUtils

# Static version for when you just have a status string and no BuildStatusManager instance
sub is_successful_status {
    my ($status) = @_;
    return defined($status) && ($status eq 'done' || $status eq 'skipped' || 
           $status eq 'validate' || $status eq 'dry-run' || $status eq 'noop');
}

# Setter for actually_executed tracking
sub set_actually_executed {
    my ($self, $node, $executed, $invocation_id) = @_;
    $invocation_id //= 1;
    # Store by node key (string) as hash key, with invocation_id as sub-key
    my $node_key = $node->key;
    $self->{actually_executed}{$node_key}{$invocation_id} = $executed;
}

# --- Breadcrumb Trail System ---
# Track complete status transition history for audit and execution order

sub add_breadcrumb {
    my ($self, $node, $status, $phase, $invocation_id) = @_;
    $invocation_id //= 1;
    
    my $stable_key = $self->_generate_stable_key($node);
    my $timestamp = time() - $self->{build_start_time}; # seconds since build start
    
    # Initialize breadcrumbs array if it doesn't exist
    $self->{breadcrumbs}{$stable_key} = [] unless exists $self->{breadcrumbs}{$stable_key};
    
    # Add breadcrumb entry
    push @{$self->{breadcrumbs}{$stable_key}}, {
        timestamp => $timestamp,
        status => $status,
        phase => $phase,
        invocation_id => $invocation_id
    };
    
    # Track execution order for all status transitions, not just 'ready'
    # This gives us a complete chronological view of when each node became eligible for execution
    if ($status eq 'ready' || $status eq 'executing' || $status eq 'running') {
        # Check if node is already in execution order to prevent duplicates
        my $already_in_order = grep { $_->{node_key} eq $stable_key } @{$self->{execution_order}};
        unless ($already_in_order) {
            push @{$self->{execution_order}}, {
                node_key => $stable_key,
                node_name => $node->name,
                timestamp => $timestamp,
                phase => $phase,
                status => $status
            };
        }
    }
    
    # Also track completion statuses for better execution order visibility
    if ($status eq 'done' || $status eq 'failed' || $status eq 'skipped' || $status eq 'not-run') {
        # Find existing entry and update its status, or add new entry if not found
        my $existing_entry = undef;
        for my $entry (@{$self->{execution_order}}) {
            if ($entry->{node_key} eq $stable_key) {
                $existing_entry = $entry;
                last;
            }
        }
        
        if ($existing_entry) {
            # Update existing entry with completion status
            $existing_entry->{status} = $status;
            $existing_entry->{completion_timestamp} = $timestamp;
        } else {
            # Add new entry for completion status (in case node wasn't tracked before)
            push @{$self->{execution_order}}, {
                node_key => $stable_key,
                node_name => $node->name,
                timestamp => $timestamp,
                phase => $phase,
                status => $status,
                completion_timestamp => $timestamp
            };
        }
    }
    
    log_debug("BuildStatusManager::add_breadcrumb: " . $node->name . " -> $status (phase: $phase, time: +${timestamp}s)");
}

sub get_breadcrumbs {
    my ($self, $node, $invocation_id) = @_;
    $invocation_id //= 1;
    
    my $stable_key = $self->_generate_stable_key($node);
    return $self->{breadcrumbs}{$stable_key} || [];
}

sub get_execution_order {
    my ($self) = @_;
    return @{$self->{execution_order}};
}

sub get_execution_order_names {
    my ($self) = @_;
    return map { $_->{node_name} } @{$self->{execution_order}};
}

sub clear_breadcrumbs {
    my ($self) = @_;
    $self->{breadcrumbs} = {};
    $self->{execution_order} = [];
    $self->{build_start_time} = time();
}

sub get_build_summary {
    my ($self) = @_;
    
    # Count nodes by status
    my $total_nodes = 0;
    my $failed_nodes = 0;
    my $successful_nodes = 0;
    my $skipped_nodes = 0;
    
    # Iterate through the nested hash structure: {stable_key}{invocation_id} = status
    print "[DEBUG] get_all_status: type of status = " . ref($self->{status}) . "\n";
    print "[DEBUG] get_all_status: status value = " . (ref($self->{status}) ? "HASH" : $self->{status}) . "\n";
    print "[DEBUG] get_all_status: keys = " . join(", ", keys %{$self->{status}}) . "\n";
    for my $stable_key (keys %{$self->{status}}) {
        print "[DEBUG] get_all_status: stable_key = $stable_key, value type = " . ref($self->{status}{$stable_key}) . "\n";
        for my $invocation_id (keys %{$self->{status}{$stable_key}}) {
            my $status = $self->{status}{$stable_key}{$invocation_id};
            $total_nodes++;
            
            if ($status eq 'failed') {
                $failed_nodes++;
            } elsif ($status eq 'done') {
                $successful_nodes++;
            } elsif ($status eq 'skipped') {
                $skipped_nodes++;
            }
        }
    }
    
    return {
        total_nodes => $total_nodes,
        failed_nodes => $failed_nodes,
        successful_nodes => $successful_nodes,
        skipped_nodes => $skipped_nodes,
        nodes_in_execution_order => scalar(@{$self->{execution_order}}),
        build_duration => time() - $self->{build_start_time},
        execution_order => [@{$self->{execution_order}}]
    };
}

# Helper method to determine phase from status
sub _determine_phase_from_status {
    my ($self, $status) = @_;
    
    # Map status to build phase
    if ($status eq 'pending') {
        return 'initialization';
    } elsif ($status eq 'ready') {
        return 'execution_preparation';
    } elsif ($status eq 'executing' || $status eq 'running') {
        return 'execution';
    } elsif ($status eq 'done' || $status eq 'failed' || $status eq 'skipped') {
        return 'completion';
    } elsif ($status eq 'validate' || $status eq 'dry-run') {
        return 'validation';
    } else {
        return 'unknown';
    }
}

# Initialize all nodes in a registry to 'pending' status
sub initialize_all_nodes {
    my ($self, $registry) = @_;
    # Get all nodes as references (not keys)
    my $all_nodes = $registry->all_nodes;
    log_debug("BuildStatusManager::initialize_all_nodes: Initializing " . scalar(keys %$all_nodes) . " nodes");
    for my $node (values %$all_nodes) {
        my $stable_key = $node->name;
        my $args = $node->args;
        if (defined($args) && ref($args) eq 'HASH' && %{$args}) {
            $stable_key .= '|' . join('|', map { "$_=$args->{$_}" } sort keys %{$args});
        }
        log_debug("BuildStatusManager::initialize_all_nodes: Setting status for node: $stable_key");
        $self->set_status($node, 'pending');
    }
    log_debug("BuildStatusManager::initialize_all_nodes: Initialization complete. Status keys: " . join(", ", keys %{$self->{status}}));
}

sub clear {
    my ($self) = @_;
    $self->{status}   = {};
    $self->{duration} = {};
    $self->{actually_executed} = {};
}

sub get_all_status {
    my ($self) = @_;
    return $self->{status} || {};
}

sub get_all_duration {
    my ($self) = @_;
    return $self->{duration} || {};
}

sub _node_key {
    my ($node) = @_;
    return $node;  # Just return the BuildNode reference, no key extraction
}

# Generate a stable key for a node based on name and args (but not memory addresses)
sub _generate_stable_key {
    my ($self, $node) = @_;
    
    # Defensive check: ensure we have a blessed BuildNode object
    unless (ref($node) && $node->isa('BuildNode')) {
        croak("_generate_stable_key called with invalid node: " . (ref($node) || 'unblessed') . " - " . $node);
    }
    
    my $stable_key = $node->name;
    
    my $args = $node->args;
    if (defined($args) && ref($args) eq 'HASH' && %{$args}) {
        # Process args carefully to avoid BuildNode reference issues
        my @arg_parts;
        for my $key (sort keys %{$args}) {
            my $value = $args->{$key};
            if (ref($value)) {
                if (ref($value) eq 'HASH') {
                    # For hash references, just use a placeholder
                    push @arg_parts, "$key=HASH";
                } elsif (ref($value) eq 'ARRAY') {
                    # For array references, just use a placeholder
                    push @arg_parts, "$key=ARRAY";
                } elsif (ref($value) && $value->can('name')) {
                    # For BuildNode references, use their name
                    push @arg_parts, "$key=" . $value->name;
                } else {
                    # For other references, use the ref type
                    push @arg_parts, "$key=" . ref($value);
                }
            } else {
                # For scalar values, use as-is
                push @arg_parts, "$key=$value";
            }
        }
        if (@arg_parts) {
            $stable_key .= '|' . join('|', @arg_parts);
        }
    }
    
    return $stable_key;
}

1;

__END__

=head1 NAME
BuildStatusManager - Encapsulates status and duration for build nodes

=head1 SYNOPSIS
  use BuildStatusManager;
  my $status_mgr = BuildStatusManager->new;
  $status_mgr->set_status($node, 'done');
  $status_mgr->set_duration($node, 42);
  $status_mgr->set_actually_executed($node, 1);
  my $status = $status_mgr->get_status($node);
  my $duration = $status_mgr->get_duration($node);
  my $did_run = $status_mgr->did_run($node);
  my $did_succeed = $status_mgr->did_succeed($node);

  # Or create with initialization in one step:
  my $status_mgr = BuildStatusManager->new_with_initialization($registry);

=head1 DESCRIPTION
This class manages status and duration for build nodes, indexed by canonical node key. It is designed to be instantiated per build execution, supporting parallel and concurrent builds.

=head2 new_with_initialization($registry)

Creates a new BuildStatusManager instance and initializes all nodes in the given registry to 'not_processed' status. This is a convenience method that combines creation and initialization in a single call.

=head2 set_status($node, $status, $invocation_id)

Sets the status for a node. Status values include: 'not_processed', 'pending', 'running', 'done', 'failed', 'skipped'.

=head2 get_status($node, $invocation_id)

Returns the status for a node. 

B<Note:> This method will croak() with an informative error message if the node has no status set. This indicates an initialization bug since all nodes should be explicitly initialized with status before get_status is called. This fail-fast behavior helps detect initialization problems early.
=head2 set_duration($node, $duration, $invocation_id)
=head2 get_duration($node, $duration, $invocation_id)
=head2 set_actually_executed($node, $executed, $invocation_id)
=head2 initialize_all_nodes($registry)

All methods accept an optional invocation_id (default 1). Status and duration are indexed by "$key|$invocation_id".

=over 4

=item initialize_all_nodes($registry)

Initializes all nodes in the given registry to 'not_processed' status. This provides explicit state management for all nodes at the start of execution without coupling graph construction to execution state.

=back

=head2 Helper Methods

=over 4

=item did_run($node, $invocation_id)

Returns true if the node was actually executed (not skipped).

=item did_succeed($node, $invocation_id)

Returns true if the node completed successfully (status 'done' or 'skipped').

=item did_fail($node, $invocation_id)

Returns true if the node failed (status 'failed').

=item is_done($node, $invocation_id)

Alias for did_succeed.

=item is_skipped($node, $invocation_id)

Returns true if the node was skipped (status 'skipped').

=item is_running($node, $invocation_id)

Returns true if the node is currently running (status 'running').

=item is_pending($node, $invocation_id)

Returns true if the node is waiting to run (status 'pending').

=back

=cut 