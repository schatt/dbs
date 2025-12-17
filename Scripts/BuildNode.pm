package BuildNode;

use strict;
use warnings;
# No need for use vars - we'll access globals via fully qualified package names
use BuildUtils qw(read_args log_debug is_successful_completion_status is_node_in_groups_ready);
use Scalar::Util qw(refaddr blessed);
use Data::Dumper;

# Constructor
sub new {
    my ($class, %fields) = @_;
    
    # Validate required fields
    die "BuildNode constructor: 'name' field is required" unless defined($fields{name}) && $fields{name} ne '';
    
    # Defensive: ensure notifies and conditional notifies are always arrayrefs of hashrefs
    for my $notif_field (qw(notifies notifies_on_success notifies_on_failure)) {
        if (exists $fields{$notif_field}) {
            if (ref $fields{$notif_field} eq 'HASH') {
                $fields{$notif_field} = [ $fields{$notif_field} ];
            } elsif (ref $fields{$notif_field} ne 'ARRAY') {
                $fields{$notif_field} = [ { name => $fields{$notif_field} } ];
        }
            for my $notify (@{ $fields{$notif_field} }) {
            if (!ref($notify)) {
                $notify = { name => $notify };
            }
            if (exists $notify->{args} && ref($notify->{args}) ne 'HASH') {
                delete $notify->{args};
            }
            if (exists $notify->{args_from} && $notify->{args_from} ne 'self') {
                delete $notify->{args_from};
            }
        }
            # Debug output for conditional notifications
            if ($notif_field ne 'notifies' && $BuildUtils::VERBOSITY_LEVEL >= 3) {
                my $count = scalar(@{ $fields{$notif_field} });
                log_debug("BuildNode constructor: $fields{name} has $count $notif_field notifications");
            }
    } else {
            $fields{$notif_field} = [];
        }
    }
    $fields{children} ||= [];
    $fields{dependencies} ||= [];
    $fields{external_dependencies} ||= [];  # External/sibling dependencies (blocking for structural readiness)
    $fields{parents} ||= [];     # Array of parent nodes
    
    # Debug: check if parents field is being set incorrectly during construction (only at high verbosity)
    if ($BuildUtils::VERBOSITY_LEVEL >= 3 && exists $fields{parents} && ref($fields{parents}) eq 'ARRAY' && @{$fields{parents}}) {
        log_debug("BUILDNODE-DEBUG: Node '$fields{name}' constructed with " . scalar(@{$fields{parents}}) . " parents:");
        for my $i (0..$#{$fields{parents}}) {
            my $parent = $fields{parents}->[$i];
            if (ref($parent) && blessed($parent) && $parent->can('name')) {
                log_debug("  [$i] BuildNode: " . $parent->name);
            } elsif (ref($parent) eq 'ARRAY') {
                log_debug("  [$i] ARRAY: [" . join(',', @$parent) . "]");
            } else {
                log_debug("  [$i] " . ref($parent) . ": " . (defined($parent) ? "object" : "undef"));
            }
        }
    }
    $fields{blocked_by} ||= {};  # Hash of node_key => 1 for nodes that block this one
    $fields{blocks} ||= {};      # Hash of node_key => 1 for nodes this one blocks
    $fields{child_order_by_parent} ||= {};  # Hash: parent_key => order (1, 2, 3, etc.)
    
    # Conditional notification system
    $fields{success_notify} ||= [];  # Array of hashes: [{node_ref => false}, ...]
    $fields{failure_notify} ||= [];  # Array of hashes: [{node_ref => false}, ...]
    $fields{conditional} ||= 0;      # Flag: 1 if this node only runs when conditions are met
    # After initializing fields, add this diagnostic check
    if ((($fields{type} // '') ne 'group') && $fields{children} && ref($fields{children}) eq 'ARRAY' && @{ $fields{children} }) {
        my $children_str = join(', ', map { $_->{name} // '<unknown>' } @{ $fields{children} });
        warn "[BUILDNODE-WARN] Non-group node '$fields{name}' (type: $fields{type}) constructed with children: $children_str\n";
    }
    return bless \%fields, $class;
}

# Accessors
sub name         { $_[0]->{name} }
sub get_args     { read_args($_[0]->{args}) }
sub args         { $_[0]->{args} }
sub set_args     { $_[0]->{args} = $_[1] }
sub type         { $_[0]->{type} }
sub command      { $_[0]->{command} }
sub build_command{ $_[0]->{build_command} }
sub description  { $_[0]->{description} }
sub children     { $_[0]->{children} || [] }
sub dependencies { $_[0]->get_all_dependencies() }
sub external_dependencies { $_[0]->{external_dependencies} || [] }
sub parent_group { $_[0]->{parent_group} }

sub set_parent_group {
    my ($self, $value) = @_;
    $self->{parent_group} = $value;
}
sub force_run_due_to_requires_execution_of { $_[0]->{force_run_due_to_requires_execution_of} }
sub set_force_run_due_to_requires_execution_of { $_[0]->{force_run_due_to_requires_execution_of} = $_[1] }
sub always_run   { $_[0]->{always_run} }
sub inputs       { $_[0]->{inputs} || [] }
sub outputs      { $_[0]->{outputs} || [] }
sub log_file     { $_[0]->{log_file} }
sub archive      { $_[0]->{archive} }

# Conditional notification system accessors
sub success_notify { $_[0]->{success_notify} || [] }
sub failure_notify { $_[0]->{failure_notify} || [] }
sub conditional   { $_[0]->{conditional} || 0 }
sub set_conditional { $_[0]->{conditional} = $_[1] }

# Methods to manage conditional notification arrays
sub add_success_notify {
    my ($self, $node_ref) = @_;
    $self->{success_notify} ||= [];
    push @{$self->{success_notify}}, {
        node => $node_ref,
        status => 0  # 0 = not-run, 1 = true, false = false
    };
}

sub add_failure_notify {
    my ($self, $node_ref) = @_;
    $self->{failure_notify} ||= [];
    push @{$self->{failure_notify}}, {
        node => $node_ref,
        status => 0  # 0 = not-run, 1 = true, false = false
    };
}

sub update_success_notify {
    my ($self, $node_ref, $status) = @_;
    my $success_array = $self->{success_notify} || [];
    log_debug("update_success_notify: Looking for " . $node_ref->name . " in " . $self->name . "'s success_notify array");
    log_debug("update_success_notify: Array has " . scalar(@$success_array) . " entries");
    for my $i (0..$#$success_array) {
        my $entry = $success_array->[$i];
        log_debug("update_success_notify: Checking entry $i");
        if (refaddr($entry->{node}) == refaddr($node_ref)) {
            if ($status) {
                $entry->{status} = 1;  # Mark as true
                log_debug("update_success_notify: Updated " . $entry->{node}->name . " to status 1");
            } else {
                $entry->{status} = -1;  # Mark as not-met
                log_debug("update_success_notify: Updated " . $entry->{node}->name . " to status -1");
            }
            return;
        }
    }
    log_debug("update_success_notify: Could not find " . $node_ref->name . " in array");
}

sub update_failure_notify {
    my ($self, $node_ref, $status) = @_;
    my $failure_array = $self->{failure_notify} || [];
    log_debug("update_failure_notify: Looking for " . $node_ref->name . " in " . $self->name . "'s failure_notify array");
    log_debug("update_failure_notify: Array has " . scalar(@$failure_array) . " entries");
    for my $i (0..$#$failure_array) {
        my $entry = $failure_array->[$i];
        log_debug("update_failure_notify: Checking entry $i");
        if (refaddr($entry->{node}) == refaddr($node_ref)) {
            if ($status) {
                $entry->{status} = 1;  # Mark as true
                log_debug("update_failure_notify: Updated " . $entry->{node}->name . " to status 1");
            } else {
                $entry->{status} = -1;  # Mark as not-met
                log_debug("update_failure_notify: Updated " . $entry->{node}->name . " to status -1");
            }
            return;
        }
    }
    log_debug("update_failure_notify: Could not find " . $node_ref->name . " in array");
}

sub all_success_conditions_met {
    my ($self) = @_;
    my $success_array = $self->{success_notify} || [];
    return 0 if @$success_array == 0;  # No conditions = not-met
    
    # Check if any entries are still "not-run" (status 0)
    for my $entry (@$success_array) {
        log_debug("all_success_conditions_met: Entry has status " . $entry->{status});
        return -1 if $entry->{status} == 0;  # Still waiting for this notifier
    }
    
    # All notifiers have completed, check if at least one succeeded
    for my $entry (@$success_array) {
        return 1 if $entry->{status} == 1;  # At least one succeeded
    }
    
    return 0;  # All failed (status -1)
}

sub all_failure_conditions_met {
    my ($self) = @_;
    my $failure_array = $self->{failure_notify} || [];
    return 0 if @$failure_array == 0;  # No conditions = not-met
    
    # Check if any entries are still "not-run" (status 0)
    for my $entry (@$failure_array) {
        log_debug("all_failure_conditions_met: Entry has status " . $entry->{status});
        return -1 if $entry->{status} == 0;  # Still waiting for this notifier
    }
    
    # All notifiers have completed, check if at least one failed
    for my $entry (@$failure_array) {
        return 1 if $entry->{status} == 1;  # At least one failed
    }
    
    return 0;  # All succeeded (status -1)
}

sub add_notifies_on_success {
    my ($self, $target_node) = @_;
    $self->{notifies_on_success} ||= [];
    push @{$self->{notifies_on_success}}, $target_node;
}

sub add_notifies_on_failure {
    my ($self, $target_node) = @_;
    $self->{notifies_on_failure} ||= [];
    push @{$self->{notifies_on_failure}}, $target_node;
}
sub continue_on_error { $_[0]->{continue_on_error} }
sub status       { $_[0]->{status} }
sub duration     { $_[0]->{duration} }
sub all_targets  { $_[0]->{all_targets} }
sub args_optional { $_[0]->{args_optional} }
sub dependency_names { $_[0]->{dependency_names} || [] }
sub variables    { $_[0]->{variables} }
sub requires_execution_of { $_[0]->{requires_execution_of} || [] }
sub parallel     { $_[0]->{parallel} }
sub is_parallel  { $_[0]->{parallel} ? 1 : 0 }
sub parallel_count { $_[0]->{parallel_count} || 1 }

# Get the effective parallel capacity for this node
sub get_parallel_capacity {
    my ($self, $groups_ready_ref) = @_;
    
    # Check if we have a dependency group (child_order: 0) that's not complete
    if ($groups_ready_ref) {
        for my $child (@{$self->children // []}) {
            if (($child->get_child_order($self) // 0) == 0) {
                my $child_status = $main::STATUS_MANAGER->get_status($child);
                if (!is_successful_completion_status($child_status)) {
                    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                        log_debug("get_parallel_capacity: " . $self->name . " has incomplete dependency group " . $child->name . " - capacity = 0");
                    }
                    return 0; # No additional capacity until dependency group completes
                }
            }
        }
    }
    
    # Normal parallel capacity logic
    return 1 unless $self->is_parallel;  # Sequential
    
    if (defined $self->parallel_count) {
        return $self->parallel_count;  # Specific limit (e.g., parallel: 4)
    } else {
        # parallel: true - use global default from buildconfig.yml
        # For now, use a reasonable default; this will be enhanced to read from config
        return 8;  # Default global limit
    }
}

# Child ordering accessors - per parent
sub get_child_order { 
    my ($self, $parent) = @_;
    # If no parent specified, try to get from first parent (for backward compatibility)
    unless ($parent) {
        my $parents = $self->get_clean_parents;
        $parent = $parents->[0] if $parents && @$parents;
    }
    return 999 unless $parent;  # Default if no parent specified
    my $parent_key = ref($parent) && $parent->can('key') ? $parent->key : $parent;
    return defined($self->{child_order_by_parent}{$parent_key}) ? $self->{child_order_by_parent}{$parent_key} : 999;
}
sub set_child_order { 
    my ($self, $order, $parent) = @_;
    return unless defined($order) && $parent;
    my $parent_key = ref($parent) && $parent->can('key') ? $parent->key : $parent;
    $self->{child_order_by_parent}{$parent_key} = $order;
}

# Blocking system accessors
sub blocked_by   { $_[0]->{blocked_by} || {} }
sub blocks       { $_[0]->{blocks} || {} }

# Add required_args accessor
sub required_args { $_[0]->{required_args} || [] }

# Push-based completion_notify mechanism
sub add_completion_notify_target {
    my ($self, $dependent) = @_;
    $self->{completion_notify_targets} ||= {};
    my $key = ref($dependent) ? $dependent->key : $dependent;
    $self->{completion_notify_targets}{$key} = $dependent;
}

sub notify_dependents_on_completion {
    my ($self) = @_;
    return unless $self->{completion_notify_targets};
    for my $dep_key (keys %{ $self->{completion_notify_targets} }) {
        my $dependent = $self->{completion_notify_targets}{$dep_key};
        $dependent->receive_completion_notify($self) if ref($dependent) && $dependent->can('receive_completion_notify');
    }
}

sub receive_completion_notify {
    my ($self, $completed_node) = @_;
    $self->{outstanding_completions} ||= {};
    my $key = ref($completed_node) ? $completed_node->key : $completed_node;
    $self->{outstanding_completions}{$key} = 1;
    # Check if all expected completions have been received
    if ($self->all_completions_received) {
        $self->on_all_completions;
    }
}

sub expect_completion_from {
    my ($self, $node) = @_;
    $self->{expected_completions} ||= {};
    my $key = ref($node) ? $node->key : $node;
    $self->{expected_completions}{$key} = 0;
}

sub all_completions_received {
    my ($self) = @_;
    return 0 unless $self->{expected_completions};
    for my $k (keys %{ $self->{expected_completions} }) {
        return 0 unless $self->{outstanding_completions} && $self->{outstanding_completions}{$k};
    }
    return 1;
}

sub on_all_completions {
    my ($self) = @_;
    $self->{completed} = 1;
    $self->notify_dependents_on_completion;
}

# Encapsulated add_child method
sub add_child {
    my ($self, $child) = @_;
    $self->{children} ||= [];
    
    # Check for duplicates to prevent the same child from being added multiple times
    for my $existing_child (@{ $self->{children} }) {
        if ($existing_child == $child) {
            # Child already exists, skip adding
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("add_child: " . $self->name . " skipping duplicate child " . $child->name);
            }
            return;
        }
    }
    
    push @{ $self->{children} }, $child if ref($child);
}

# Check if adding a dependency would create a cycle
sub would_create_cycle {
    my ($self, $new_dep, $visited) = @_;
    $visited ||= {};
    
    # If we've already visited this node, we have a cycle
    if ($visited->{ $self->key }) {
        return 1;
    }
    
    # Mark current node as visited
    $visited->{ $self->key } = 1;
    
    # If the new dependency is the current node, that's a direct cycle
    if ($new_dep->key eq $self->key) {
        return 1;
    }
    
    # Check if the new dependency depends on us (directly or indirectly)
    # This is the key insight: we're checking if adding this dependency would create a cycle
    # by seeing if the new dependency already depends on us
    # All node types should be handled identically
    if (ref($new_dep)) {
        if ($new_dep->depends_on($self, $visited)) {
            return 1;
        }
    }
    
    return 0;
}

# Check if this node depends on another node (directly or indirectly)
sub depends_on {
    my ($self, $target, $visited) = @_;
    $visited ||= {};
    
    # If we've already visited this node, avoid infinite recursion
    if ($visited->{ $self->key }) {
        return 0;
    }
    
    # Mark current node as visited
    $visited->{ $self->key } = 1;
    
    # Check direct dependencies
    for my $dep (@{ $self->dependencies || [] }) {
        if (ref($dep)) {
            # Direct dependency
            if ($dep->key eq $target->key) {
                log_debug("DEPENDS_ON: " . $self->name . " directly depends on " . $target->name);
                return 1;
            }
            # Indirect dependency
            if ($dep->depends_on($target, $visited)) {
                log_debug("DEPENDS_ON: " . $self->name . " indirectly depends on " . $target->name . " via " . $dep->name);
                return 1;
            }
        }
    }
    
    return 0;
}

# Encapsulated add_dependency method with cycle detection
sub add_dependency {
    my ($self, $dep) = @_;
    $self->{dependencies} ||= [];
    
    # This method now adds INTERNAL dependencies (non-blocking for structural readiness)
    
    # Check for duplicate dependencies to prevent multiple instances
    for my $existing_dep (@{ $self->{dependencies} }) {
        my $existing_key;
        my $new_key;
        
        # Get existing dependency key
        if (ref($existing_dep)) {
            $existing_key = $existing_dep->key;
        } else {
            $existing_key = $existing_dep; # String dependency
        }
        
        # Get new dependency key
        if (ref($dep)) {
            $new_key = $dep->key;
        } else {
            $new_key = $dep; # String dependency
        }
        
        # Ensure both keys are defined before comparison
        next unless defined($existing_key) && defined($new_key);
        
        # Compare keys (both can be strings or both can be object keys)
        if ($existing_key eq $new_key) {
            # Debug output should respect verbosity
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("add_dependency: " . $self->name . " skipping duplicate " . (ref($dep) ? ref($dep) . ":" . $dep->name : "string:" . $dep) . " (key: $new_key)");
            }
            return; # Skip adding duplicate dependency
        } else {
            # Debug output to see what keys are being compared
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("add_dependency: key comparison - existing: '$existing_key' vs new: '$new_key'");
            }
        }
    }
    

    
    # Cycle detection is now handled in process_node_relationships_immediately
    
    # Debug output should respect verbosity
    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
        log_debug("add_dependency: " . $self->name . " adding " . (ref($dep) ? ref($dep) . ":" . $dep->name : "string:" . $dep));
    }
    push @{ $self->{dependencies} }, $dep if ref($dep);
    
    # Also establish the parent relationship: the dependency should have this node as a parent
    # This is correct for the build system architecture where dependencies create parent relationships
    if (ref($dep) && $dep->can('add_parent')) {
        $dep->add_parent($self);
    }
}

# Add external dependency method for sibling dependencies (blocking for structural readiness)
sub add_external_dependency {
    my ($self, $dep) = @_;
    $self->{external_dependencies} ||= [];
    
    # Check for duplicate external dependencies to prevent multiple instances
    for my $existing_dep (@{ $self->{external_dependencies} }) {
        my $existing_key;
        my $new_key;
        
        # Get existing dependency key
        if (ref($existing_dep)) {
            $existing_key = $existing_dep->key;
        } else {
            $existing_key = $existing_dep; # String dependency
        }
        
        # Get new dependency key
        if (ref($dep)) {
            $new_key = $dep->key;
        } else {
            $new_key = $dep; # String dependency
        }
        
        # Ensure both keys are defined before comparison
        next unless defined($existing_key) && defined($new_key);
        
        # Compare keys (both can be strings or both can be object keys)
        if ($existing_key eq $new_key) {
            # Debug output should respect verbosity
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("add_external_dependency: " . $self->name . " skipping duplicate " . (ref($dep) ? ref($dep) . ":" . $dep->name : "string:" . $dep) . " (key: $new_key)");
            }
            return; # Skip adding duplicate dependency
        }
    }
    
    # Debug output should respect verbosity
    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
        log_debug("add_external_dependency: " . $self->name . " adding " . (ref($dep) ? ref($dep) . ":" . $dep->name : "string:" . $dep));
    }
    push @{ $self->{external_dependencies} }, $dep if ref($dep);
    
    # External dependencies don't establish parent relationships
    # They are sibling dependencies that block structural readiness
}

# Update add_notify to store BuildNode references
sub add_notify {
    my ($self, $notify) = @_;
    $self->{notifies} ||= [];
    # Only store BuildNode references, not hash structures
    if (ref($notify) && $notify->can('key')) {
        push @{ $self->{notifies} }, $notify;
    }
}

# Accessor method for unconditional notifications - returns BuildNode references
sub get_notifies {
    my ($self) = @_;
    return $self->notifies || [];
}

# Add conditional notification methods - store BuildNode references
sub add_notify_on_success {
    my ($self, $notify) = @_;
    $self->{notifies_on_success} ||= [];
    # Only store BuildNode references, not hash structures
    if (ref($notify) && $notify->can('key')) {
        push @{ $self->{notifies_on_success} }, $notify;
    }
}

sub add_notify_on_failure {
    my ($self, $notify) = @_;
    $self->{notifies_on_failure} ||= [];
    # Only store BuildNode references, not hash structures
    if (ref($notify) && $notify->can('key')) {
        push @{ $self->{notifies_on_failure} }, $notify;
    }
}

# Add reverse notification relationship method
sub add_notified_by {
    my ($self, $notifier) = @_;
    $self->{notified_by} ||= [];
    push @{ $self->{notified_by} }, $notifier if ref($notifier);
}

# Bidirectional notification methods that establish both sides of the relationship
sub add_notify_bidirectional {
    my ($self, $target) = @_;
    # Add target to source's notifies
    $self->add_notify($target);
    # Add source to target's notified_by
    $target->add_notified_by($self);
}

sub add_notify_on_success_bidirectional {
    my ($self, $target) = @_;
    # Add target to source's notifies_on_success
    $self->add_notify_on_success($target);
    # Add source to target's notified_by
    $target->add_notified_by($self);
}

sub add_notify_on_failure_bidirectional {
    my ($self, $target) = @_;
    # Add target to source's notifies_on_failure
    $self->add_notify_on_failure($target);
    # Add source to target's notified_by
    $self->add_notified_by($target);
}

# Accessor methods for conditional notifications - returns BuildNode references
sub get_notifies_on_success {
    my ($self) = @_;
    return $self->notifies_on_success || [];
}

sub get_notifies_on_failure {
    my ($self) = @_;
    return $self->notifies_on_failure || [];
}

# Accessor method for reverse notification relationships
sub get_notified_by {
    my ($self) = @_;
    return $self->notified_by || [];
}

# Helper method to get notification target name consistently
sub get_notification_target_name {
    my ($notify) = @_;
    if (ref($notify) eq 'HASH') {
        return $notify->{name};
    } elsif (ref($notify) && UNIVERSAL::can($notify, 'name')) {
        return $notify->name;
    } else {
        return $notify;
    }
}

# Helper method to get notification args consistently
sub get_notification_args {
    my ($notify) = @_;
    if (ref($notify) eq 'HASH') {
        return $notify->{args};
    } elsif (ref($notify) && UNIVERSAL::can($notify, 'get_args')) {
        return $notify->get_args;
    } else {
        return {};
    }
}

# Notification accessors
sub notifies_list { $_[0]->{notifies} || [] }
sub notifies      { $_[0]->{notifies} || [] } # alias for symmetry
sub notifies_on_success { $_[0]->{notifies_on_success} || [] }
sub notifies_on_failure { $_[0]->{notifies_on_failure} || [] }

# Type helpers
sub is_group    { $_[0]->{type} && $_[0]->{type} eq 'group' }
sub is_task     { $_[0]->{type} && $_[0]->{type} eq 'task' }
sub is_platform { $_[0]->{type} && $_[0]->{type} eq 'platform' }
sub is_leaf     { !( $_[0]->children && @{ $_[0]->children } ) }
sub is_dependency_group { $_[0]->{name} && $_[0]->{name} =~ /_dependency_group$/ }

# Graph key - unique identifier for this specific node instance
sub key {
    my ($self) = @_;
    
    # Ensure we have a valid name before proceeding
    my $name = $self->name;
    unless (defined($name) && $name ne '') {
        # This should never happen, but let's be defensive
        die "BuildNode key() called on node with undefined or empty name";
    }
    
    # If canonical key is stored, use it as the base for the graph key
    if (exists $self->{canonical_key} && defined($self->{canonical_key}) && $self->{canonical_key} ne '') {
        # Add instance identifier to make this unique
        return $self->{canonical_key} . '|' . refaddr($self);
    }
    
    # Fallback: generate a unique graph key
    my $graph_key = $name;
    my $args = $self->get_args;
    if ($args && ref($args) eq 'HASH' && %{$args}) {
        $graph_key .= '|' . join(',', map { "$_=$args->{$_}" } sort keys %{$args});
    }
    $graph_key .= '|' . refaddr($self);
    
    return $graph_key;
}

# Identity key for identical node detection (what was used for deduplication)
sub identity_key {
    my ($self) = @_;
    
    # If identity key is stored, use it (preferred)
    if (exists $self->{identity_key}) {
        return $self->{identity_key};
    }
    
    # If canonical key is stored, use it as the identity key
    if (exists $self->{canonical_key} && defined($self->{canonical_key}) && $self->{canonical_key} ne '') {
        $self->{identity_key} = $self->{canonical_key};
        return $self->{identity_key};
    }
    
    # Generate identity key: name + args (without instance)
    my $args_str = '';
    my $args = $self->get_args;
    if ($args && ref($args) eq 'HASH' && %{$args}) {
        $args_str = join(',', map { "$_=$args->{$_}" } sort keys %{$args});
    }
            $self->{identity_key} = $self->name . '|' . $args_str;
    
    return $self->{identity_key};
}

# Add argument validation method
sub validate_args {
    my ($self) = @_;
    my @errors;
    my @warns;
    # Only validate tasks
    if ($self->is_task) {
        my $cmd = $self->command // '';
        my $args = $self->get_args;
        my $task_name = $self->name;
        # Find all variables used in the command
        my @cmd_vars;
        push @cmd_vars, $cmd =~ /\$\{(\w+)\}/g;
        push @cmd_vars, map { "arg$_" } ($cmd =~ /\$arg(\d+)/g);
        # Check required_args strictly
        if ($self->{required_args} && ref $self->{required_args} eq 'ARRAY') {
            for my $req (@{ $self->{required_args} }) {
                unless (defined $args && ref $args eq 'HASH' && exists $args->{$req}) {
                    push @errors, "Task '$task_name' is missing required argument '$req' (required_args)";
                }
            }
        }
        # For all variables used in the command, warn if missing (unless required_args already errored or args_optional is true)
        for my $var (@cmd_vars) {
            next if $self->{required_args} && ref $self->{required_args} eq 'ARRAY' && grep { $_ eq $var } @{ $self->{required_args} };
            next if $self->args_optional; # Skip warnings for optional args
            unless (defined $args && ref $args eq 'HASH' && exists $args->{$var}) {
                push @warns, "Task '$task_name' command uses variable '$var' but it is not present in args: $cmd";
            }
        }
    }
    return { errors => \@errors, warns => \@warns };
}

# Validate notifications and dependencies
sub validate_notifications_and_dependencies {
    my ($self, $registry) = @_;
    my @errors;
    my $all_nodes = $registry->all_nodes;
    # Validate notifies
    for my $notify (@{ $self->notifies // [] }) {
        my $target = $notify->{name};
        my $notify_args = $notify->{args};
        my $target_key = $target;
        if ($notify_args && ref $notify_args eq 'HASH' && %$notify_args) {
            $target_key .= '|' . join(',', map { "$_=$notify_args->{$_}" } sort keys %$notify_args);
        }
        unless (exists $all_nodes->{$target_key}) {
            push @errors, "Notification from '" . $self->key . "' to undefined target '$target_key'";
        }
    }
    # Validate dependencies
    for my $dep (@{ $self->dependencies // [] }) {
        my $dep_key = $dep->key;
        unless (exists $all_nodes->{$dep_key}) {
            push @errors, "Dependency from '" . $self->key . "' to undefined target '$dep_key'";
        }
    }
    return \@errors;
}

# Traversal method: recursively visits dependencies and children, calling callback for each node.
sub traverse {
    my ($self, $callback, $seen) = @_;
    $seen ||= {};
    return if $seen->{ $self->key }++;
    $callback->($self);
    for my $dep (@{ $self->dependencies // [] }) {
        $dep->traverse($callback, $seen) if ref($dep) && $dep->can('traverse');
    }
    for my $child (@{ $self->children // [] }) {
        $child->traverse($callback, $seen) if ref($child) && $child->can('traverse');
    }
}

=head2 traverse($callback, $seen)

Recursively visits each node (dependencies and children), calling $callback->($node) for each, skipping already-seen nodes. Optionally pass a hashref $seen to track visited nodes.

=cut

=head1 DESIGN NOTE

All BuildNode field access outside the BuildNode class must use accessors/methods (e.g., $node->name, $node->get_args). Treat BuildNode fields as private. Only utility code that must support both BuildNode and hashref may use hash access, and must prefer accessors when available.

=cut

# Setter for continue_on_error
sub set_continue_on_error {
    my ($self, $value) = @_;
    $self->{continue_on_error} = $value;
}

# Setter for parallel
sub set_parallel {
    my ($self, $value) = @_;
    $self->{parallel} = $value;
}

# --- Multiple Parents Management ---
# WHAT: Manages relationships between a node and multiple parent groups
# HOW: Tracks references to parent groups and checks if any parent is ready
# WHY: Enables a node to be a dependency of multiple groups without duplication

sub parents {
    my ($self) = @_;
    my $raw_parents = $self->{parents};
    my $result = $raw_parents || [];
    
    # Simple debug: just show parent names to avoid Data::Dumper circular references
    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
        my $parent_names = $self->get_parent_names;
        # Debug output removed for cleaner logs
    }
    
    return $result;
}

sub add_parent {
    my ($self, $parent_node) = @_;
    return unless $parent_node && ref($parent_node);
    
    # Only allow blessed BuildNode references
    unless (blessed($parent_node) && $parent_node->isa('BuildNode')) {
        log_debug("add_parent: " . $self->name . " rejecting non-BuildNode parent: " . ref($parent_node));
        return;
    }
    
    # Debug: log what's being passed to add_parent
    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
        log_debug("add_parent: " . $self->name . " adding parent: BuildNode:" . $parent_node->name);
    }
    
    # Don't add self as parent
    return if $parent_node == $self;
    
    # Check if already in list
    for my $existing (@{ $self->get_clean_parents }) {
        return if $existing == $parent_node;
    }
    
    # Add to our parents list
    push @{ $self->{parents} }, $parent_node;
}

sub remove_parent {
    my ($self, $parent_node) = @_;
    return unless $parent_node && ref($parent_node);
    
    # Remove from parents list - filter out non-BuildNode references first
    my $clean_parents = $self->get_clean_parents;
    @{ $self->{parents} } = @$clean_parents;
    
    # Now remove the specific parent
    @{ $self->{parents} } = grep { $_ != $parent_node } @{ $self->{parents} };
}

sub get_parents {
    my ($self) = @_;
    return $self->get_clean_parents;
}

# Get clean parents list - filter out circular references and ensure only BuildNode objects
sub get_clean_parents {
    my ($self) = @_;
    my $raw_parents = $self->{parents} || [];
    my @clean_parents;
    
    for my $parent (@$raw_parents) {
        # Only include if it's a blessed BuildNode reference
        if (ref($parent) && blessed($parent) && $parent->isa('BuildNode')) {
            push @clean_parents, $parent;
        } else {
            # Log problematic parent for debugging
            if ($BuildUtils::VERBOSITY_LEVEL >= 2) {
                log_debug("get_clean_parents: " . $self->name . " filtering out non-BuildNode parent: " . ref($parent));
            }
        }
    }
    
    return \@clean_parents;
}

# Get parent names for safe display (avoids Data::Dumper circular references)
sub get_parent_names {
    my ($self) = @_;
    my $clean_parents = $self->get_clean_parents;
    return [map { $_->name } @$clean_parents];
}

sub has_parent {
    my ($self, $parent_node) = @_;
    return 0 unless $parent_node && ref($parent_node);
    
    for my $parent (@{ $self->get_clean_parents }) {
        return 1 if $parent == $parent_node;
    }
    
    return 0;
}

# Check if this node has any parents at all
sub has_any_parents {
    my ($self) = @_;
    my $clean_parents = $self->get_clean_parents;
    return scalar(@$clean_parents) > 0;
}

# --- Blocking System Management ---
# WHAT: Manages blocking relationships between nodes for proper execution ordering
# HOW: Tracks which nodes block this one and which nodes this one blocks
# WHY: Ensures children inherit parent blockers and respect group dependencies

sub add_blocker {
    my ($self, $blocker_node) = @_;
    return unless $blocker_node && ref($blocker_node);
    
    my $blocker_key = $blocker_node->key;
    return unless defined($blocker_key) && $blocker_key ne '';
    
    $self->blocked_by->{$blocker_key} = 1;
    
    # Add us to their blocks list (bidirectional relationship)
    $blocker_node->add_blocked_node($self);
}

sub add_blocked_node {
    my ($self, $blocked_node) = @_;
    return unless $blocked_node && ref($blocked_node);
    
    my $blocked_key = $blocked_node->key;
    return unless defined($blocked_key) && $blocked_key ne '';
    
    $self->blocks->{$blocked_key} = 1;
}

sub remove_blocker {
    my ($self, $blocker_node) = @_;
    return unless $blocker_node && ref($blocker_node);
    
    my $blocker_key = $blocker_node->key;
    return unless defined($blocker_key) && $blocker_key ne '';
    
    delete $self->blocked_by->{$blocker_key};
    
    # Remove us from their blocks list
    $blocker_node->remove_blocked_node($self);
}

sub remove_blocked_node {
    my ($self, $blocked_node) = @_;
    return unless $blocked_node && ref($blocked_node);
    
    my $blocked_key = $blocked_node->key;
    return unless defined($blocked_key) && $blocked_key ne '';
    
    delete $self->blocks->{$blocked_key};
}

sub is_blocked {
    my ($self) = @_;
    return scalar(keys %{ $self->blocked_by || {} }) > 0;
}

sub get_blockers {
    my ($self) = @_;
    return keys %{ $self->blocked_by || {} };
}

sub get_blocked_nodes {
    my ($self) = @_;
    return keys %{ $self->blocks || {} };
}

# Helper methods for dependency management
sub get_internal_dependencies {
    my ($self) = @_;
    return $_[0]->{dependencies} || [];
}

sub get_external_dependencies {
    my ($self) = @_;
    return $_[0]->{external_dependencies} || [];
}

    # DRY method: returns union of all dependency types for backward compatibility
    sub get_all_dependencies {
        my ($self) = @_;
        my @all_deps;
        push @all_deps, @{ $self->{dependencies} || [] };
        push @all_deps, @{ $self->{external_dependencies} || [] };
        return \@all_deps;
    }
    
        # Check if this node can move to ready queue based on parallel/sequential constraints
    sub can_move_to_ready {
        my ($self, $groups_ready_ref, $status_ref) = @_;
        
        # Debug: log what we're checking
        if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
            log_debug("can_move_to_ready: Checking node " . $self->name . " with " . scalar(@{ $self->parents // [] }) . " parents");
        }
        
        # If no parents, this is a root node - should be able to move to ready immediately
        # Root nodes are the starting point of the build system and have no parent constraints
        if (!$self->parents || @{$self->parents} == 0) {
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("can_move_to_ready: Root node " . $self->name . " - no parent constraints, can move to ready immediately");
            }
            return 1;
        }
        
        # Check if this is the next available child for ANY parent (OR logic)
        my $can_move_from_any_parent = 0;
        for my $parent (@{ $self->parents // [] }) {
            my $parent_key = $parent->key;
            next unless exists $groups_ready_ref->{$parent_key};
            
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("can_move_to_ready: Parent " . $parent->name . " is in groups_ready");
            }
            
            # Check if this node can move to ready based on parallel capacity OR if it's a dependency group
            my $capacity = $parent->get_parallel_capacity($groups_ready_ref);
            my $current_count = $parent->children_in_ready_count();
            
            # Special case: child_order: 0 nodes (dependency groups) can always move to ready
            # OR if parallel capacity allows it
            if (($self->get_child_order($parent) // 999) == 0 || $current_count < $capacity) {
                if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                    if (($self->get_child_order($parent) // 999) == 0) {
                        log_debug("can_move_to_ready: " . $self->name . " is dependency group (child_order: 0) - bypassing capacity check");
                    } else {
                        log_debug("can_move_to_ready: " . $self->name . " has parallel capacity available: $current_count < $capacity");
                    }
                }
            } else {
                if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                    log_debug("can_move_to_ready: " . $self->name . " blocked by capacity: $current_count >= $capacity");
                }
                next; # Blocked by capacity
            }
            
            # Sequential order was already checked when moving to GR
            # No need to re-check here - if the node is in GR, it can move to ready when ready
            
            # This parent allows the node to move to ready
            $can_move_from_any_parent = 1;
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("can_move_to_ready: Parent " . $parent->name . " allows " . $self->name . " to move to ready");
            }
            last; # Found a parent that allows it, no need to check others
        }
        
        return $can_move_from_any_parent;
    }
    
    # Get the next sequential child by child_order
    sub get_next_sequential_child {
        my ($self) = @_;
        
        # Enhanced debugging for function entry
        if ($BuildUtils::VERBOSITY_LEVEL >= 2) {
            log_debug("=== get_next_sequential_child ENTRY ===");
            log_debug("Parent: " . $self->name . " (type: " . ($self->type // 'unknown') . ")");
            log_debug("Total children: " . scalar(@{$self->children // []}));
            
            # Summary of all children before processing
            log_debug("=== CHILDREN SUMMARY ===");
            for my $i (0..$#{$self->children // []}) {
                my $child = $self->children->[$i];
                my $order = $child->get_child_order($self) // 0;
                my $status = $main::STATUS_MANAGER->get_status($child);
                my $is_dep_group = ($order == 0) ? 'YES' : 'NO';
                log_debug("Child[$i]: " . $child->name . " (order: $order, status: $status, dep_group: $is_dep_group, type: " . ($child->type // 'unknown') . ")");
            }
            log_debug("=== END CHILDREN SUMMARY ===");
        }
        
        # Sort children by child_order (relative to $self)
        my @sorted_children = sort { ($a->get_child_order($self) // 0) <=> ($b->get_child_order($self) // 0) } @{$self->children // []};
        
        if (@sorted_children == 0) {
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("get_next_sequential_child: No children to coordinate");
            }
            return undef;
        }
        
        # Debug child ordering
        if ($BuildUtils::VERBOSITY_LEVEL >= 2) {
            log_debug("=== CHILD ORDERING DEBUG ===");
            for my $i (0..$#sorted_children) {
                my $child = $sorted_children[$i];
                my $order = $child->get_child_order($self) // 0;
                my $status = $main::STATUS_MANAGER->get_status($child);
                log_debug("Child[$i]: " . $child->name . " (order: $order, status: $status, type: " . ($child->type // 'unknown') . ")");
            }
            log_debug("=== END CHILD ORDERING DEBUG ===");
        }
        
        # Find the first child that's ready AND all lower-order siblings are either done or blocked
        for my $child (@sorted_children) {
            my $child_status = $main::STATUS_MANAGER->get_status($child);
            my $child_order = $child->get_child_order($self) // 0;
            
            # Enhanced debugging for each child
            if ($BuildUtils::VERBOSITY_LEVEL >= 2) {
                log_debug("=== PROCESSING CHILD: " . $child->name . " ===");
                log_debug("Child order: $child_order");
                log_debug("Child status: $child_status");
                log_debug("Child type: " . ($child->type // 'unknown'));
                log_debug("Is dependency group: " . ($child_order == 0 ? 'YES' : 'NO'));
            }
            
            # Skip children that are already completed
            if (is_successful_completion_status($child_status)) {
                if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                    log_debug("get_next_sequential_child: Skipping completed child " . $child->name . " (status: $child_status)");
                }
                next;
            }
            
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("get_next_sequential_child: Found pending child " . $child->name . " (status: $child_status)");
            }
            
            # Check if this child is ready
            my $is_eligible = $self->is_coordination_eligible_status($child);
            if ($BuildUtils::VERBOSITY_LEVEL >= 2) {
                log_debug("Coordination eligibility check: $is_eligible");
                log_debug("Status '$child_status' is eligible: " . ($is_eligible ? 'YES' : 'NO'));
            }
            
            if ($is_eligible) {
                if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                    log_debug("get_next_sequential_child: Child " . $child->name . " is ready for coordination");
                }
                
                # Check if ALL lower-order siblings are either done or blocked
                my $all_lower_siblings_handled = 1;
                my $lower_sibling_count = 0;
                my $blocking_sibling = undef;
                
                if ($BuildUtils::VERBOSITY_LEVEL >= 2) {
                    log_debug("=== CHECKING LOWER SIBLINGS for " . $child->name . " ===");
                }
                
                for my $lower_child (@sorted_children) {
                    my $lower_order = $lower_child->get_child_order($self) // 0;
                    next if $lower_order >= $child_order;
                    
                    $lower_sibling_count++;
                    my $lower_status = $main::STATUS_MANAGER->get_status($lower_child);
                    
                    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                        log_debug("get_next_sequential_child: Checking lower sibling " . $lower_child->name . " (order: " . $lower_order . ", status: $lower_status)");
                    }
                    
                    # Special debug for dependency groups (child_order: 0)
                    if ($lower_order == 0) {
                        if ($BuildUtils::VERBOSITY_LEVEL >= 2) {
                            log_debug("get_next_sequential_child: CRITICAL: Dependency group " . $lower_child->name . " (order: $lower_order) has status: $lower_status");
                            if (!is_successful_completion_status($lower_status)) {
                                log_debug("get_next_sequential_child: BLOCKING: Child " . $child->name . " cannot proceed until dependency group " . $lower_child->name . " completes");
                                $blocking_sibling = $lower_child;
                            }
                        }
                    }
                    
                    if (!is_successful_completion_status($lower_status)) {
                        # Lower sibling is not completed - this child cannot go yet
                        if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                            log_debug("get_next_sequential_child: Child " . $child->name . " cannot go yet - lower sibling " . $lower_child->name . " is not completed (status: $lower_status)");
                        }
                        $all_lower_siblings_handled = 0;
                        $blocking_sibling = $lower_child;
                        last;
                    }
                }
                
                if ($BuildUtils::VERBOSITY_LEVEL >= 2) {
                    log_debug("Lower siblings checked: $lower_sibling_count");
                    log_debug("All lower siblings handled: " . ($all_lower_siblings_handled ? 'YES' : 'NO'));
                    if ($blocking_sibling) {
                        log_debug("Blocking sibling: " . $blocking_sibling->name . " (order: " . ($blocking_sibling->get_child_order($self) // 0) . ", status: " . $main::STATUS_MANAGER->get_status($blocking_sibling) . ")");
                    }
                }
                
                if ($all_lower_siblings_handled) {
                    if ($BuildUtils::VERBOSITY_LEVEL >= 2) {
                        log_debug("=== SUCCESS: Returning " . $child->name . " ===");
                        log_debug("All lower siblings handled successfully");
                        log_debug("Child is coordination eligible");
                        log_debug("Child order: $child_order");
                    }
                    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                        log_debug("get_next_sequential_child: Returning " . $child->name . " - all lower siblings handled");
                    }
                    return $child;
                } else {
                    if ($BuildUtils::VERBOSITY_LEVEL >= 2) {
                        log_debug("=== BLOCKED: " . $child->name . " cannot proceed ===");
                        log_debug("Blocked by: " . ($blocking_sibling ? $blocking_sibling->name : 'unknown'));
                    }
                }
            } else {
                if ($BuildUtils::VERBOSITY_LEVEL >= 2) {
                    log_debug("=== SKIPPED: " . $child->name . " not eligible ===");
                    log_debug("Status '$child_status' is not coordination eligible");
                }
            }
        }
        
        # Enhanced debugging for function exit
        if ($BuildUtils::VERBOSITY_LEVEL >= 2) {
            log_debug("=== get_next_sequential_child EXIT ===");
            log_debug("No eligible children found - returning undef");
            log_debug("All children processed without finding a suitable candidate");
        }
        
        return undef;
    }
    
    # Check if a status is valid for coordination (ready to be processed)
    sub is_coordination_eligible_status {
        my ($node_ref) = @_;
        
        # Debug the input and output
        if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
            log_debug("BuildNode::is_coordination_eligible_status: Input node = '$node_ref' (ref: " . ref($node_ref) . ")");
        }
        
        # Use centralized function from BuildStatusManager for DRY principle
        my $result = $main::STATUS_MANAGER->is_coordination_eligible_status($node_ref);
        
        if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
            log_debug("BuildNode::is_coordination_eligible_status: Status manager returned: $result");
        }
        
        return $result;
    }

    # Check if a status is blocking (not ready for execution)
    sub is_blocking_status {
        my ($self, $node) = @_;
        # Use centralized function from BuildStatusManager for DRY principle
        return $main::STATUS_MANAGER->is_blocking_status($node);
    }

    # Check if a specific child is ready to coordinate, considering sibling order, parallel capacity, and child_order: 0 special case
    sub ready_to_coordinate_child {
        my ($self, $child, $groups_ready_ref) = @_;
        
        # Special case: child_order: 0 (dependency groups) can coordinate IF their dependencies and notifiers are satisfied
        if (($child->get_child_order($self) // 0) == 0) {
            if ($BuildUtils::VERBOSITY_LEVEL >= 2) {
                log_debug("ready_to_coordinate_child: Checking dependency group " . $child->name . " (child_order: 0)");
            }
            
            # For dependency groups, check dependencies and notifiers directly (don't call is_ready_for_execution)
            # Check if all dependencies are satisfied
            for my $dep (@{ $child->get_all_dependencies // [] }) {
                my $dep_status = $main::STATUS_MANAGER->get_status($dep);
                if (!is_successful_completion_status($dep_status)) {
                    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                        log_debug("ready_to_coordinate_child: " . $child->name . " dependency " . $dep->name . " not satisfied (status: $dep_status)");
                    }
                    return 0;
                }
            }
            
            # Check if all notifiers are satisfied
            for my $notifier (@{ $child->get_notified_by // [] }) {
                my $notifier_status = $main::STATUS_MANAGER->get_status($notifier);
                if ($notifier_status eq 'pending' || $notifier_status eq 'in-progress') {
                    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                        log_debug("ready_to_coordinate_child: " . $child->name . " notifier " . $notifier->name . " not satisfied (status: $notifier_status)");
                    }
                    return 0;
                }
            }
            
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("ready_to_coordinate_child: " . $child->name . " has child_order: 0 and dependencies/notifiers satisfied - allowed to coordinate (bypassing parallel capacity check)");
            }
            return 1;
        }
        
        # For non-dependency-group children, check if this child is the next sequential child
        if ($BuildUtils::VERBOSITY_LEVEL >= 2) {
            log_debug("=== ready_to_coordinate_child: Checking sequential order ===");
            log_debug("Parent: " . $self->name . " (type: " . ($self->type // 'unknown') . ")");
            log_debug("Child to check: " . $child->name . " (child_order: " . ($child->get_child_order($self) // 0) . ")");
        }
        
        my $next_sequential = $self->get_next_sequential_child();
        
        if ($BuildUtils::VERBOSITY_LEVEL >= 2) {
            log_debug("Parent's next sequential child: " . ($next_sequential ? $next_sequential->name : 'undefined'));
            if ($next_sequential) {
                log_debug("Next sequential order: " . ($next_sequential->get_child_order($self) // 0));
                log_debug("Next sequential status: " . ($main::STATUS_MANAGER->get_status($next_sequential) // 'unknown'));
            }
        }
        
        unless ($next_sequential && $next_sequential eq $child) {
            if ($BuildUtils::VERBOSITY_LEVEL >= 2) {
                log_debug("=== ready_to_coordinate_child: Sequential check FAILED ===");
                log_debug("This child is NOT the next sequential child");
                if ($next_sequential) {
                    log_debug("Expected: " . $next_sequential->name . " (key: " . $next_sequential->key . ")");
                    log_debug("Actual: " . $child->name . " (key: " . $child->key . ")");
                } else {
                    log_debug("No next sequential child found");
                }
            }
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("ready_to_coordinate_child: " . $child->name . " is not the next sequential child");
            }
            return 0;
        }
        
        if ($BuildUtils::VERBOSITY_LEVEL >= 2) {
            log_debug("=== ready_to_coordinate_child: Sequential check PASSED ===");
            log_debug("This child IS the next sequential child");
        }
        
        # Check parallel capacity for coordination
        my $capacity = $self->get_parallel_capacity($groups_ready_ref);
        my $current_coordinating = 0;
        
        # For regular children (child_id != 0), check if there's an incomplete dependency group blocking them
        if (($child->get_child_order($self) // 0) != 0) {
            # Check if any dependency group (child_order: 0) is incomplete
            for my $dep_child (@{$self->children // []}) {
                if (($dep_child->get_child_order($self) // 0) == 0) {
                    my $dep_status = $main::STATUS_MANAGER->get_status($dep_child);
                    if (!is_successful_completion_status($dep_status)) {
                        if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                            log_debug("ready_to_coordinate_child: " . $child->name . " cannot coordinate - dependency group " . $dep_child->name . " is incomplete (status: $dep_status)");
                        }
                        return 0; # Blocked by incomplete dependency group
                    }
                }
            }
        }
        
        # Count how many children are currently in the ready queue (executing)
        for my $coord_child (@{$self->children // []}) {
            # Check if this child is in the ready queue
            if (grep { $_->key eq $coord_child->key } @::ready_queue_nodes) {
                $current_coordinating++;
            }
        }
        
        if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
            log_debug("ready_to_coordinate_child: Parent " . $self->name . " capacity: " . $capacity . ", currently coordinating: " . $current_coordinating);
        }
        
        if ($current_coordinating >= $capacity) {
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("ready_to_coordinate_child: " . $child->name . " cannot coordinate - at capacity limit");
            }
            return 0;
        }
        
        # Check if this child is already coordinating
        if (exists $groups_ready_ref->{$child}) {
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("ready_to_coordinate_child: " . $child->name . " is already coordinating");
            }
            return 0;
        }
        
        return 1;
    }
    
    # Get the next child that should coordinate, considering both sibling order AND parallel capacity
    sub get_next_coordination_child {
        my ($self, $status_ref, $groups_ready_ref) = @_;
        
        # First, get the next sequential child
        my $next_sequential = $self->get_next_sequential_child($status_ref);
        return undef unless $next_sequential;
        
        # Special case: dependency groups (child_order: 0) can always coordinate
        if (($next_sequential->get_child_order($self) // 0) == 0) {
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("get_next_coordination_child: Dependency group " . $next_sequential->name . " (child_order: 0) - always allowed to coordinate");
            }
            return $next_sequential;
        }
        
        # Now check if we have parallel capacity for coordination (only for non-dependency-group children)
        my $capacity = $self->get_parallel_capacity($status_ref, $groups_ready_ref);
        my $current_coordinating = 0;
        
        # Count how many children are currently coordinating (in groups_ready)
        for my $child (@{$self->children // []}) {
            if (exists $groups_ready_ref->{$child->key}) {
                $current_coordinating++;
            }
        }
        
        if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
            log_debug("get_next_coordination_child: Parent " . $self->name . " capacity: $capacity, currently coordinating: $current_coordinating");
        }
        
        # Only return the child if we have capacity for more coordination
        if ($current_coordinating < $capacity) {
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("get_next_coordination_child: Returning " . $next_sequential->name . " - capacity available for coordination");
            }
            return $next_sequential;
        } else {
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("get_next_coordination_child: NOT returning " . $next_sequential->name . " - no capacity for coordination");
            }
            return undef;
        }
    }
    
    # Check if this node should coordinate next based on sibling order and completion status
    sub should_coordinate_next {
        my ($self, $groups_ready_ref) = @_;
        
        # If no parent, always coordinate next (root nodes)
        return 1 unless $self->parents && @{$self->parents};
        
        # For nodes with multiple parents (e.g., deduplicated nodes), check if ANY parent in GR allows coordination
        # This allows a node to coordinate via one parent even if another parent isn't ready yet
        my $can_coordinate_via_any_parent = 0;
        
        # Check each parent to see if this node should coordinate next
        for my $parent (@{ $self->get_clean_parents }) {
            my $my_child_id = $self->get_child_order($parent);
            
            # Skip parents that are not in GR - they can't coordinate this node yet
            unless (is_node_in_groups_ready($parent, $groups_ready_ref)) {
                if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                    log_debug("should_coordinate_next: " . $self->name . " skipping parent " . $parent->name . " - not in groups_ready");
                }
                next;  # Skip this parent, check other parents
            }
            
            # If this is a dependency group and parent is in GR, coordinate immediately
            if ($my_child_id == 0) {
                if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                    log_debug("should_coordinate_next: " . $self->name . " (dependency group) can coordinate immediately - parent " . $parent->name . " in groups_ready");
                }
                return 1;  # Dependency groups can coordinate immediately when parent is in GR
            }
            
            # If parent is a dependency group (parent's child_order == 0), children can coordinate immediately
            # Dependency groups don't have their own dependency groups - they ARE the dependency group
            # Need to check parent's child_order relative to its parent
            my $parent_parents = $parent->get_clean_parents;
            my $parent_child_order = 999;
            if ($parent_parents && @$parent_parents) {
                $parent_child_order = $parent->get_child_order($parent_parents->[0]) // 999;
            }
            if ($parent_child_order == 0) {
                # Parent is a dependency group, so children (starting with child_order 1) can coordinate
                # Skip the dependency group complete check and proceed to coordination logic
                if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                    log_debug("should_coordinate_next: " . $self->name . " parent " . $parent->name . " is a dependency group, children can coordinate");
                }
            } else {
                # For regular children of non-dependency-group parents: check if parent's dependency group is complete
                unless ($parent->is_dependency_group_complete()) {
                    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                        log_debug("should_coordinate_next: " . $self->name . " cannot coordinate via parent " . $parent->name . " - dependency group not complete");
                    }
                    next;  # Skip this parent, check other parents
                }
            }
            
            # Now proceed with normal coordination logic for this parent...
            my $children_completed = $parent->number_of_children_completed();
            my $parallel_level = $parent->get_parallel_count();
            
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("should_coordinate_next: " . $self->name . " checking coordination via parent " . $parent->name . " - completed: $children_completed, parallel: $parallel_level, my_child_id: $my_child_id");
            }
            
            # DEBUG TEST: If highest # of children complete is higher than my id, exit/fail and output what the $self->children contains
            if ($children_completed > $my_child_id) {
                log_debug("should_coordinate_next: FAILURE - children_completed ($children_completed) > my_child_id ($my_child_id) for node " . $self->name);
                log_debug("Parent: " . $parent->name);
                log_debug("Parent's children:");
                for my $i (0..$#{$parent->children // []}) {
                    my $child = $parent->children->[$i];
                    my $child_status = $main::STATUS_MANAGER->get_status($child);
                    my $child_order = $child->get_child_order($parent) // 0;
                    log_debug("  [$i] " . $child->name . " (order: $child_order, status: $child_status)");
                }
                log_debug("End of parent's children list");
                next;  # Skip this parent, check other parents
            }
            
            # Check coordination eligibility based on parent type
            my $can_coordinate_via_this_parent = 0;
            if ($parent->is_parallel()) {
                # Parallel: check if enough children have completed
                $can_coordinate_via_this_parent = ($children_completed + $parallel_level) >= $my_child_id;
                if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                    log_debug("should_coordinate_next: " . $self->name . " parallel check via " . $parent->name . " - ($children_completed + $parallel_level) >= $my_child_id = " . ($can_coordinate_via_this_parent ? "YES" : "NO"));
                }
            } else {
                # Sequential: use single source of truth for coordination logic
                # Pass the specific parent we're checking (for nodes with multiple parents)
                my $math_check = $self->is_sequential_coordination_ready($children_completed, $parent);
                
                if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                    if (!$math_check) {
                        log_debug("should_coordinate_next: " . $self->name . " sequential check via " . $parent->name . " failed - math_check: " . ($math_check ? "YES" : "NO") . " (completed: $children_completed, my_child_id: $my_child_id)");
                    }
                }
                
                $can_coordinate_via_this_parent = $math_check;
            }
            
            # If this parent allows coordination, we can coordinate (OR logic across parents)
            if ($can_coordinate_via_this_parent) {
                if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                    log_debug("should_coordinate_next: " . $self->name . " can coordinate via parent " . $parent->name);
                }
                $can_coordinate_via_any_parent = 1;
                last;  # Found a parent that allows coordination, no need to check others
            }
        }
        
        if ($can_coordinate_via_any_parent) {
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("should_coordinate_next: Node " . $self->name . " can coordinate via at least one parent");
            }
            return 1;
        }
        
        if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
            log_debug("should_coordinate_next: Node " . $self->name . " should NOT coordinate next - no parent in GR allows coordination");
        }
        return 0;
    }
    
    # Get the actual parallel count for this node (actual number, default, or 1)
    sub get_parallel_count {
        my ($self) = @_;
        
        # If parallel is a number, return that number
        if (defined $self->{parallel} && $self->{parallel} =~ /^\d+$/) {
            return $self->{parallel};
        }
        
        # If parallel is true, return project default (assume 2 for now)
        if ($self->{parallel}) {
            return 2;  # TODO: Get from project config
        }
        
        # Default to sequential (1)
        return 1;
    }
    
    # Get the number of children that have completed successfully
    sub number_of_children_completed {
        my ($self) = @_;
        
        my $completed_count = 0;
        for my $child (@{ $self->children // [] }) {
            my $child_status = $main::STATUS_MANAGER->get_status($child);
            if (is_successful_completion_status($child_status)) {
                $completed_count++;
            }
        }
        
        return $completed_count;
    }
    
    # Single source of truth for sequential coordination logic
    # child_id 0 coordinates when 0 children completed
    # child_id 1 coordinates when 1 child completed
    # child_id 2 coordinates when 2 children completed
    # This uses zero-based indexing (dependency groups start at child_id 0)
    sub is_sequential_coordination_ready {
        my ($self, $children_completed, $parent) = @_;
        my $my_child_id = $self->get_child_order($parent);
        return ($my_child_id == $children_completed);
    }
    
    # Check if this child is the next sequential child that should coordinate
    sub is_next_sequential_child {
        my ($self) = @_;
        
        # Get parent and check if this is the next child in sequence
        my $parent = $self->get_clean_parents->[0];  # Assume single parent for now
        return 0 unless $parent;
        
        my $my_child_id = $self->get_child_order($parent);
        my $children_completed = $parent->number_of_children_completed();
        
        # Use single source of truth for sequential coordination logic
        return $self->is_sequential_coordination_ready($children_completed, $parent);
    }
    
    # Check if this parent's dependency group (child_id 0) is complete
    sub is_dependency_group_complete {
        my ($self) = @_;
        
        # Find the dependency group (child with child_order: 0) of this parent
        for my $child (@{ $self->children // [] }) {
            if (($child->get_child_order($self) // 999) == 0) {
                my $child_status = $main::STATUS_MANAGER->get_status($child);
                return is_successful_completion_status($child_status);
            }
        }
        
        # No dependency group found
        return 1;  # No dependency group to wait for
    }
    
    # Check if a dependency group (child_order: 0) is blocking other children
    sub is_dependency_group_blocking {
        my ($self) = @_;
        
        # Check each parent to see if their dependency group is blocking this node
        for my $parent (@{ $self->get_clean_parents }) {
            # Find the dependency group (child with child_order: 0) of this parent
            for my $sibling (@{ $parent->children // [] }) {
                if (($sibling->get_child_order($parent) // 0) == 0) {
                    # Skip self-blocking: a dependency group should not be blocked by itself
                    if ($sibling == $self) {
                        if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                            log_debug("is_dependency_group_blocking: " . $self->name . " skipping self-blocking check");
                        }
                        last; # Skip to next parent
                    }
                    
                    my $sibling_key = $sibling->key;
                    my $sibling_status = $main::STATUS_MANAGER->get_status($sibling);
                    
                    # If the parent's dependency group is not complete, it blocks this node
                    if (!is_successful_completion_status($sibling_status)) {
                        if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                            log_debug("is_dependency_group_blocking: " . $self->name . " is BLOCKED by parent " . $parent->name . "'s dependency group $sibling_key (status: $sibling_status)");
                        }
                        return 1; # Blocked
                    } else {
                        if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                            log_debug("is_dependency_group_blocking: " . $self->name . " NOT blocked by parent " . $parent->name . "'s dependency group $sibling_key (status: $sibling_status)");
                        }
                    }
                    last; # Only one dependency group per parent
                }
            }
        }
        
        return 0; # Not blocked by any parent's dependency group
    }
    
    # Count how many children are currently in the ready queue
    sub children_in_ready_count {
        my ($self) = @_;
        my $count = 0;
        for my $child (@{ $self->children // [] }) {
            $count++ if ($main::STATUS_MANAGER->get_status($child) // '') eq 'ready';
        }
        return $count;
    }
    
    # Check if a node has any dependencies (internal or external)
    sub has_any_dependencies {
        my ($self) = @_;
        my $deps = $self->get_all_dependencies;
        return @$deps > 0;
    }

    # Check if a node has any external dependencies
    sub has_external_dependencies {
        my ($self) = @_;
        my $ext_deps = $self->get_external_dependencies;
        return @$ext_deps > 0;
    }

    # Check if a node has any notifiers
    sub has_any_notifiers {
        my ($self) = @_;
        my $notifiers = $self->get_notified_by;
        return @$notifiers > 0;
    }

    # Check if a node has any failed dependencies
    sub has_failed_dependencies {
        my ($self) = @_;
        
        for my $dep (@{ $self->get_all_dependencies // [] }) {
            my $dep_status = $main::STATUS_MANAGER->get_status($dep);
            
            if ($dep_status eq 'failed' || $dep_status eq 'error') {
                return 1; # Found a failed dependency
            }
        }
        return 0; # No failed dependencies
    }

    # Check if a node is ready for execution
    sub is_ready_for_execution {
        my ($self) = @_;
        
        # Step 1: Check if this node is in groups_ready (if applicable)
        # Note: Dependency groups (child_order = 0) are automatically added to GR
        if ($self->type eq 'group' || $self->type eq 'platform') {
            my $node_in_gr = is_node_in_groups_ready($self, \%main::GROUPS_READY_NODES);
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("is_ready_for_execution: " . $self->name . " in GR: " . ($node_in_gr ? "YES" : "NO"));
            }
            return 0 unless $node_in_gr;
        }
        
        # Step 2: Check if all children are complete
        # Since every node has an auto-generated dependency group, we just check if children are done
        for my $child (@{ $self->children // [] }) {
            my $child_status = $main::STATUS_MANAGER->get_status($child);
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("is_ready_for_execution: " . $self->name . " child " . $child->name . " status: " . $child_status);
            }
            return 0 unless is_successful_completion_status($child_status);
        }
        
        # Step 3: For non-dependency groups, check if parent's dependency group is complete
        # For dependency groups (child_order = 0): this check is not applicable (always true)
        # For regular children (child_order > 0): parent's dependency group must be complete
        my $parents = $self->get_clean_parents;
        if ($parents && @$parents) {
            my $my_child_order = $self->get_child_order($parents->[0]);
            if ($my_child_order != 0) {
                # Find parent's dependency group (child_order = 0) and check if it's complete
                for my $parent (@$parents) {
                    if (defined $parent && $parent->can('children')) {
                        for my $sibling (@{ $parent->children // [] }) {
                            if (($sibling->get_child_order($parent) // 0) == 0) {  # dependency group
                                my $sibling_status = $main::STATUS_MANAGER->get_status($sibling);
                                if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                                    log_debug("is_ready_for_execution: " . $self->name . " checking parent dep group " . $sibling->name . " status: " . $sibling_status);
                                }
                                return 0 unless is_successful_completion_status($sibling_status);
                            }
                        }
                    }
                }
            }
        }
        
        return 1;
    }

=head1 COMPLETION NOTIFY MODEL

The BuildNode class implements a push-based, event-driven completion_notify model for signaling node completion. This ensures that a node is only considered complete when all of its notifies and children (for groups) have completed. The model is uniform for all node types, cycle-safe, and thoroughly tested.

See Scripts/COMPLETION_NOTIFY_DOCUMENTATION.md for full documentation and usage examples.

=head1 TESTING

Comprehensive tests for the completion_notify model are provided in:
- Scripts/t/BuildNode_completion_notify.t
- Scripts/t/BuildUtils_completion_notify.t

Run all build system tests with:

  cd Scripts
  ./run_build_tests.sh

=cut

1;

__END__

=head1 NAME
BuildNode - Encapsulates a build system node (task, platform, or group)

=head1 SYNOPSIS
  use BuildNode;
  my $node = BuildNode->new(name => 'foo', type => 'task', ...);
  print $node->name;
  print $node->key;

=head1 DESCRIPTION
This class encapsulates all node data and provides accessors, keying, and notification handling for the build system.

=cut 