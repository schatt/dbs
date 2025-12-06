package BuildExecutionEngine;

use strict;
use warnings;
use Carp;
use List::Util qw(min);
use Scalar::Util qw(blessed);
use BuildUtils qw(
    log_debug log_info log_error
    add_to_ready_queue add_to_groups_ready
    remove_from_ready_queue remove_from_groups_ready remove_from_ready_pending_parent
    is_node_in_groups_ready get_eligible_pending_parent_nodes
    has_ready_nodes get_next_ready_node
    get_ready_pending_parent_size get_groups_ready_size get_ready_queue_size
    is_successful_completion_status expand_command_args
);
use BuildStatusManager;

=head1 NAME

BuildExecutionEngine - Encapsulates the three-phase execution loop for the build system

=head1 SYNOPSIS

    use BuildExecutionEngine;
    
    my $engine = BuildExecutionEngine->new(
        registry       => $registry,
        status_manager => $status_manager,
        is_dry_run     => 0,
        is_validate    => 0,
    );
    
    my ($success, $execution_order, $statuses, $groups_ready) = $engine->execute();

=head1 DESCRIPTION

BuildExecutionEngine encapsulates the main execution loop and three-phase coordination
logic for the Distributed Build System (DBS). This class provides:

=over 4

=item * Phase 1: Coordination - Move nodes from RPP to GR based on coordination conditions

=item * Phase 2: Execution Preparation - Move nodes from RPP to Ready queue when ready for execution

=item * Phase 3: Actual Execution - Execute nodes from Ready queue and process notifications

=back

The class accepts dependencies via constructor (registry, status manager) and provides
a clean public API through the C<execute()> method, enabling testable and maintainable
execution logic.

=cut

# Constructor
sub new {
    my ($class, %args) = @_;
    
    # Validate required arguments
    croak "BuildExecutionEngine: 'registry' argument is required" 
        unless $args{registry};
    croak "BuildExecutionEngine: 'status_manager' argument is required" 
        unless $args{status_manager};
    
    # Use a secure temporary directory if none specified
    my $default_session_dir = $args{build_session_dir};
    unless ($default_session_dir) {
        require File::Temp;
        $default_session_dir = File::Temp::tempdir(CLEANUP => 0, TMPDIR => 1);
    }
    
    my $self = {
        registry          => $args{registry},
        status_manager    => $args{status_manager},
        is_dry_run        => $args{is_dry_run} // 0,
        is_validate       => $args{is_validate} // 0,
        build_session_dir => $default_session_dir,
        
        # Callbacks for external functions (dependency injection for testability)
        # 
        # transition_node_callback: sub($node, $new_status, $status_hash, $registry)
        #   Called when a node transitions to a new status
        #   Args: $node - BuildNode object being transitioned
        #         $new_status - new status string (e.g., 'done', 'failed', 'validate')
        #         $status_hash - hash reference from status_manager->{status}
        #         $registry - BuildNodeRegistry object
        #   Returns: void
        #
        # check_notifications_callback: sub($node, $status_hash)
        #   Called to check if a conditional node's notification conditions are met
        #   Args: $node - BuildNode object to check
        #         $status_hash - hash reference from status_manager->{status}
        #   Returns: 1 if conditions are met, 0 otherwise
        #
        # sanitize_log_name_callback: sub($name)
        #   Called to sanitize a node name for use in log file names
        #   Args: $name - string node name to sanitize
        #   Returns: sanitized string safe for use as filename
        #
        transition_node_callback         => $args{transition_node_callback},
        check_notifications_callback     => $args{check_notifications_callback},
        sanitize_log_name_callback       => $args{sanitize_log_name_callback},
    };
    
    bless $self, $class;
    return $self;
}

# Accessors
sub registry          { $_[0]->{registry} }
sub status_manager    { $_[0]->{status_manager} }
sub is_dry_run        { $_[0]->{is_dry_run} }
sub is_validate       { $_[0]->{is_validate} }
sub build_session_dir { $_[0]->{build_session_dir} }

=head2 execute()

Main entry point for the execution engine. Runs the three-phase execution loop
until all nodes are processed or no progress can be made.

Returns: ($success, $execution_order, $statuses, $groups_ready)

=cut

sub execute {
    my ($self) = @_;
    
    my $registry = $self->registry;
    my $status_manager = $self->status_manager;
    
    # CRITICAL: Process notification relationships to populate BuildNode objects
    log_debug("BuildExecutionEngine::execute: processing notification relationships");
    $registry->_process_notifications();
    log_debug("BuildExecutionEngine::execute: notification relationships processed");
    
    # Get all nodes directly from the registry
    my $all_nodes = $registry->all_nodes;
    my @all_nodes_objects = grep { ref($_) && $_->isa('BuildNode') } values %$all_nodes;
    
    # Debug: log any non-BuildNode objects that were filtered out
    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
        my @all_values = values %$all_nodes;
        my $filtered_count = @all_values - @all_nodes_objects;
        if ($filtered_count > 0) {
            log_debug("BuildExecutionEngine::execute: filtered out $filtered_count non-BuildNode objects from registry");
        }
    }
    
    # Clear breadcrumbs and reset execution order tracking
    $status_manager->clear_breadcrumbs();
    
    # Initialize all nodes to pending status and add to ready_pending_parent
    for my $node (@all_nodes_objects) {
        $status_manager->set_status($node, 'pending');
        push @main::READY_PENDING_PARENT_NODES, $node;
    }
    
    # Main execution loop using three-phase approach
    my $iterations = 0;
    my $max_iterations = scalar(@all_nodes_objects) * 2; # Prevent infinite loops
    my $no_progress_count = 0;
    
    log_debug("=== BuildExecutionEngine: ENTERING MAIN EXECUTION LOOP ===");
    log_debug("Starting main execution loop with " . scalar(@all_nodes_objects) . " total nodes");
    log_debug("Initial queue states:");
    log_debug("  RPP: " . get_ready_pending_parent_size() . " nodes");
    log_debug("  Ready: " . get_ready_queue_size() . " nodes"); 
    log_debug("  GR: " . get_groups_ready_size() . " nodes");
    
    while (get_ready_queue_size() > 0 || get_ready_pending_parent_size() > 0) {
        $iterations++;
        last if $iterations > $max_iterations;
        
        log_debug("=== ITERATION $iterations ===");
        log_debug("Queue sizes: rpp=" . get_ready_pending_parent_size() . ", ready=" . get_ready_queue_size() . ", gr=" . get_groups_ready_size());
        
        # Phase 1: Coordination - Move nodes from RPP to GR based on coordination conditions
        log_debug("=== STARTING PHASE 1 ===");
        my $nodes_copied_to_gr = $self->phase1_coordination();
        log_debug("Phase 1 result: copied $nodes_copied_to_gr nodes to GR");
        
        # Phase 2: Execution Preparation - Move nodes from RPP to Ready queue when ready for execution
        log_debug("=== STARTING PHASE 2 ===");
        my $nodes_moved_to_ready = $self->phase2_execution_preparation();
        log_debug("Phase 2 result: moved $nodes_moved_to_ready nodes to Ready");
        
        # Phase 3: Actual Execution - Execute nodes from Ready queue and process notifications
        log_debug("=== STARTING PHASE 3 ===");
        my $nodes_executed = $self->phase3_actual_execution();
        log_debug("Phase 3 result: executed $nodes_executed nodes");
        
        # Debug: Show detailed queue states after each phase
        $self->_log_queue_states($iterations);
        
        # Check for no progress
        if ($nodes_copied_to_gr == 0 && $nodes_moved_to_ready == 0 && $nodes_executed == 0) {
            $no_progress_count++;
            log_debug("No progress detected in iteration $iterations (consecutive: $no_progress_count)");
            
            # Add detailed debugging for why no progress is happening
            $self->_log_no_progress_details() if $BuildUtils::VERBOSITY_LEVEL >= 2;
            
            if ($no_progress_count >= 3) {
                log_debug("Breaking loop due to no progress for $no_progress_count consecutive iterations");
                last;
            }
        } else {
            # Reset no progress counter if we made progress
            $no_progress_count = 0;
        }
        
        # Log progress summary
        log_debug("Iteration $iterations progress: copied_to_gr=$nodes_copied_to_gr, moved_to_ready=$nodes_moved_to_ready, executed=$nodes_executed");
        
        # Debug: Show execution order after each iteration
        if ($BuildUtils::VERBOSITY_LEVEL >= 2) {
            my $build_summary = $status_manager->get_build_summary();
            log_debug("Iteration $iterations execution order size: " . $build_summary->{nodes_in_execution_order});
            if ($build_summary->{nodes_in_execution_order} > 0) {
                my @order_names = $status_manager->get_execution_order_names();
                log_debug("Current execution order: " . join(", ", @order_names));
            }
        }
    }
    
    # Debug: Show loop termination details
    log_debug("=== BuildExecutionEngine: LOOP TERMINATED ===");
    log_debug("Final queue states:");
    log_debug("  RPP: " . get_ready_pending_parent_size() . " nodes");
    log_debug("  Ready: " . get_ready_queue_size() . " nodes");
    log_debug("  GR: " . get_groups_ready_size() . " nodes");
    log_debug("Total iterations: $iterations");
    
    # Final check for stalled nodes in RPP
    if (@main::READY_PENDING_PARENT_NODES > 0) {
        log_debug("Final RPP nodes remaining: " . scalar(@main::READY_PENDING_PARENT_NODES));
        for my $node (@main::READY_PENDING_PARENT_NODES) {
            log_debug("  Remaining in RPP: " . $node->name . " (status: " . $status_manager->get_status($node) . ")");
        }
    }
    
    # Log final execution order details from status manager
    my $build_summary = $status_manager->get_build_summary();
    log_debug("Status Manager execution order size: " . $build_summary->{nodes_in_execution_order});
    log_debug("Status Manager total nodes: " . $build_summary->{total_nodes});
    log_debug("Nodes in execution order vs total: " . $build_summary->{nodes_in_execution_order} . "/" . $build_summary->{total_nodes});
    
    # Check if any nodes failed
    my $failed_count = $build_summary->{failed_nodes} || 0;
    my $success = ($failed_count == 0) ? 1 : 0;
    
    # Return execution results
    return ($success, $build_summary->{execution_order}, {}, \%main::GROUPS_READY_NODES);
}

=head2 phase1_coordination()

Phase 1: Coordination - Move nodes from RPP to GR based on coordination conditions.

This phase checks each node in ready_pending_parent to see if it can be moved to groups_ready.
A node can be moved if:
- All external dependencies are satisfied
- The node can coordinate (should_coordinate_next returns true)

Returns: number of nodes copied to groups_ready

=cut

sub phase1_coordination {
    my ($self) = @_;
    my $status_manager = $self->status_manager;
    
    log_debug("phase1_coordination: starting with " . scalar(@main::READY_PENDING_PARENT_NODES) . " nodes in RPP");
    
    my $nodes_copied = 0;
    
    # Debug: log the first few nodes to see what we're working with
    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
        my $count = 0;
        for my $debug_node (get_eligible_pending_parent_nodes()) {
            $count++;
            if ($count <= 5) {  # Only log first 5 to avoid spam
                log_debug("phase1_coordination: node $count: " . (defined($debug_node) && $debug_node->can('name') ? $debug_node->name : 'unnamed'));
            }
        }
        log_debug("phase1_coordination: total nodes to process: " . scalar(get_eligible_pending_parent_nodes()));
    }
    
    # Check each node in ready_pending_parent to see if it can be moved to groups_ready
    for my $node (get_eligible_pending_parent_nodes()) {
        # Debug: check if this is actually a BuildNode object
        unless (ref($node) && $node->isa('BuildNode')) {
            log_debug("phase1_coordination: WARNING - node is not a BuildNode: " . ref($node) . " - " . $node);
            next;
        }
        
        # Additional safety check before calling get_status
        if (!defined($node) || !ref($node) || !$node->can('name')) {
            log_debug("phase1_coordination: CRITICAL - node is invalid: " . (defined($node) ? ref($node) : 'undef') . " - " . $node);
            next;
        }
        
        # FAIL FAST: Skip if already in groups_ready
        if (is_node_in_groups_ready($node, \%main::GROUPS_READY_NODES)) {
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("phase1_coordination: skipping " . $node->name . " - already in groups_ready");
            }
            next;
        }
        
        my $node_key = $node->key;
        my $current_status = $status_manager->get_status($node);
        
        # Skip nodes that are not in pending status
        next unless $current_status eq 'pending';
        
        # Check if all external dependencies are satisfied (Phase 1 only checks external deps)
        my $dependencies_satisfied = 1;
        my $deps = $node->get_external_dependencies;
        for my $dep_node (@$deps) {
            # Debug: log what we're about to pass to get_status for dependencies
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("phase1_coordination: Checking external dependency: " . (defined($dep_node) && $dep_node->can('name') ? $dep_node->name : 'unnamed'));
            }
            
            my $dep_status = $status_manager->get_status($dep_node);
            if ($dep_status ne 'done' && $dep_status ne 'skipped') {
                $dependencies_satisfied = 0;
                if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                    log_debug("phase1_coordination: External dependency " . $dep_node->name . " not satisfied (status: $dep_status)");
                }
                last;
            }
        }
        
        # Check if this node can coordinate its children (should coordinate next)
        my $can_coordinate = $node->should_coordinate_next(\%main::GROUPS_READY_NODES);
        
        # If dependencies are satisfied AND node can coordinate, copy to groups_ready
        if ($dependencies_satisfied && $can_coordinate) {
            add_to_groups_ready($node, \%main::GROUPS_READY_NODES);
            $nodes_copied++;
            log_debug("phase1_coordination: copied node " . $node->name . " to groups_ready");
            
            # OPTIMIZATION: If node has an auto-generated dependency group, automatically copy it to GR
            if ($node->can('children') && $node->children && ref($node->children) eq 'ARRAY') {
                for my $child (@{$node->children}) {
                    if (($child->get_child_order // 0) == 0) {  # dependency group (child_id 0)
                        my $dep_group_status = $status_manager->get_status($child);
                        if ($dep_group_status eq 'pending') {
                            add_to_groups_ready($child, \%main::GROUPS_READY_NODES);
                            $nodes_copied++;
                            log_debug("phase1_coordination: OPTIMIZATION: auto-copied dependency group " . $child->name . " to groups_ready");
                        }
                    }
                }
            }
        }
    }
    
    log_debug("phase1_coordination: copied $nodes_copied nodes from RPP to groups_ready");
    return $nodes_copied;
}

=head2 phase2_execution_preparation()

Phase 2: Execution Preparation - Move nodes from RPP to Ready queue when ready for execution.

This phase checks each node in RPP to see if it can be moved to the ready queue.
A node can be moved if:
- Node is in groups_ready
- Parent's dependency group (if any) is complete
- All children are complete (if node has children)
- Conditional notification conditions are met (if node is conditional)

Returns: number of nodes moved to ready queue

=cut

sub phase2_execution_preparation {
    my ($self) = @_;
    my $status_manager = $self->status_manager;
    
    log_debug("phase2_execution_preparation: starting with " . scalar(@main::READY_PENDING_PARENT_NODES) . " nodes in RPP and " . scalar(keys %main::GROUPS_READY_NODES) . " nodes in GR");
    
    my $nodes_moved = 0;
    
    # Check each node in RPP to see if it can be moved to ready queue
    for my $node (get_eligible_pending_parent_nodes()) {
        
        # Debug: check if this is actually a BuildNode object by checking for required methods
        unless (ref($node) && $node->can('name') && $node->can('key')) {
            log_debug("phase2_execution_preparation: WARNING - node is not a BuildNode: " . ref($node) . " - " . (defined($node) && $node->can('name') ? $node->name : 'unnamed'));
            next;
        }
        
        # Skip nodes that are not in pending status
        next unless $status_manager->is_pending($node);
        
        # Check if this node is in groups_ready
        unless (is_node_in_groups_ready($node)) {
            log_debug("phase2_execution_preparation: node " . $node->name . " not in groups_ready, skipping");
            next;
        }
        
        # Debug: log what we're checking
        if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
            my $child_order = $node->can('get_child_order') ? $node->get_child_order : 'UNKNOWN';
            my $has_parents = $node->has_any_parents() ? 'YES' : 'NO';
            log_debug("phase2_execution_preparation: checking node " . $node->name . " (child_order: $child_order, has_parents: $has_parents)");
        }
        
        # Additional debug for conditional nodes
        if ($node->conditional) {
            my $has_parents = $node->has_any_parents() ? 'YES' : 'NO';
            log_debug("phase2_execution_preparation: Conditional node " . $node->name . " has_parents: $has_parents");
            if ($node->has_any_parents()) {
                my $parents = $node->get_parents;
                log_debug("phase2_execution_preparation: Conditional node " . $node->name . " has " . scalar(@$parents) . " parents");
                for my $parent (@$parents) {
                    log_debug("phase2_execution_preparation:   Parent: " . $parent->name);
                }
            }
        }
        
        # Start pessimistic - node is not ready by default
        my $ready_for_execution = 0;
        
        # Check if node has any parents
        if ($node->has_any_parents()) {
            my $parents = $node->get_parents;
            
            # Debug: log parent checking
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("phase2_execution_preparation: node " . $node->name . " has parents, checking coordination readiness");
            }
            
            # Check each parent for coordination readiness
            for my $parent (@$parents) {
                # Parent must be in groups_ready
                next unless is_node_in_groups_ready($parent);
                
                # Check if parent's dependency group (child_id 0) is complete
                my $dependency_group_complete = 1;
                if ($parent->can('children') && $parent->children && ref($parent->children) eq 'ARRAY') {
                    for my $child (@{$parent->children}) {
                        if (($child->get_child_order // 999) == 0) {  # dependency group (child_id 0)
                            my $dep_group_status = $status_manager->get_status($child);
                            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                                log_debug("phase2_execution_preparation: checking parent " . $parent->name . " dependency group " . $child->name . " status: " . $dep_group_status);
                            }
                            if (!is_successful_completion_status($dep_group_status)) {
                                $dependency_group_complete = 0;
                                last;
                            }
                        }
                    }
                }
                
                # Single check: child_id == 0 || child_id 0 complete
                if (($node->get_child_order // 999) == 0 || $dependency_group_complete) {
                    $ready_for_execution = 1;
                    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                        if (($node->get_child_order // 999) == 0) {
                            log_debug("phase2_execution_preparation: node " . $node->name . " is a dependency group (child_id 0), can execute immediately");
                        } else {
                            log_debug("phase2_execution_preparation: node " . $node->name . " is ready for execution (parent " . $parent->name . " dependency group complete)");
                        }
                    }
                    last;  # Found one ready parent
                }
            }
        } else {
            # No parents = root node, always ready TO COORDINATE
            if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                log_debug("phase2_execution_preparation: node " . $node->name . " has no parents (root node), always ready to coordinate");
            }
            $ready_for_execution = 1;
        }
        
        # UNIVERSAL CHECK: If this node has children, they must all be complete before it can execute
        if ($ready_for_execution && $node->children && ref($node->children) eq 'ARRAY' && @{$node->children}) {
            my $all_children_complete = 1;
            for my $child (@{$node->children}) {
                my $child_status = $status_manager->get_status($child);
                if (!is_successful_completion_status($child_status)) {
                    $all_children_complete = 0;
                    if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                        log_debug("phase2_execution_preparation: node " . $node->name . " cannot execute - child " . $child->name . " not complete (status: " . ($child_status // 'undefined') . ")");
                    }
                    last;
                }
            }
            if (!$all_children_complete) {
                $ready_for_execution = 0;
                if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
                    log_debug("phase2_execution_preparation: node " . $node->name . " not ready - waiting for all children to complete");
                }
            }
        }
        
        # Additional check for conditional nodes - this overrides the parent/children logic
        if ($node->conditional) {
            log_debug("phase2_execution_preparation: Checking conditional node " . $node->name . " for readiness");
            my $notifications_ok = $self->_check_notifications_succeeded($node);
            if (!$notifications_ok) {
                $ready_for_execution = 0;
                log_debug("phase2_execution_preparation: Conditional node " . $node->name . " conditions not met, staying in RPP");
            } else {
                $ready_for_execution = 1;
                log_debug("phase2_execution_preparation: Conditional node " . $node->name . " conditions met, ready for execution");
            }
        }
        
        # Move from RPP to Ready if conditions are met
        if ($ready_for_execution) {
            add_to_ready_queue($node);
            remove_from_ready_pending_parent($node);  # Remove from RPP
            
            # Set node status to 'ready' - this will automatically add breadcrumb and track execution order
            $status_manager->set_status($node, 'ready');
            
            $nodes_moved++;
            log_debug("phase2_execution_preparation: moved node " . $node->name . " from RPP to ready queue");
        }
    }
    
    log_debug("phase2_execution_preparation: moved $nodes_moved nodes from RPP to ready queue");
    return $nodes_moved;
}

=head2 phase3_actual_execution()

Phase 3: Actual Execution - Execute nodes from Ready queue and process notifications.

This phase executes all nodes in the ready queue:
- Validates nodes aren't already completed (error detection)
- Executes commands based on mode (validate, dry-run, or real)
- Updates node status
- Processes notifications to dependent nodes

Returns: number of nodes executed

=cut

sub phase3_actual_execution {
    my ($self) = @_;
    my $status_manager = $self->status_manager;
    my $registry = $self->registry;
    my $is_validate = $self->is_validate;
    my $is_dry_run = $self->is_dry_run;
    my $build_session_dir = $self->build_session_dir;
    
    log_debug("phase3_actual_execution: starting with " . scalar(@main::READY_QUEUE_NODES) . " nodes in ready queue");
    
    my $nodes_executed = 0;
    
    # Execute all nodes in the ready queue
    while (my $node = get_next_ready_node()) {
        my $node_key = $node->key;
        
        # Check if node is already completed - this should not happen!
        my $current_status = $status_manager->get_status($node);
        if (BuildStatusManager::is_successful_status($current_status)) {
            log_error("phase3_actual_execution: FATAL ERROR - already completed node " . $node->name . " (status: $current_status) found in ready queue!");
            log_error("This indicates a serious queue management bug. Terminating build to prevent data corruption.");
            
            # DEBUG: Output queue sizes and node details to diagnose the issue
            log_error("DEBUG INFO - Queue sizes when error occurred:");
            log_error("  Ready queue size: " . scalar(@main::READY_QUEUE_NODES));
            log_error("  Groups ready size: " . scalar(keys %main::GROUPS_READY_NODES));
            log_error("  RPP size: " . scalar(@main::READY_PENDING_PARENT_NODES));
            my $build_summary = $status_manager->get_build_summary();
            log_error("  Total execution order: " . $build_summary->{nodes_in_execution_order});
            log_error("  Node key: " . $node->key);
            log_error("  Node name: " . $node->name);
            log_error("  Node status: " . $current_status);
            
            # Check if this node appears multiple times in the ready queue
            my $node_count = grep { $_->key eq $node->key } @main::READY_QUEUE_NODES;
            log_error("  This node appears $node_count times in ready queue");
            
            log_error("");
            log_error("RECOVERY: This error indicates a bug in the build system, not in your build configuration.");
            log_error("Please report this issue with the above debug information.");
            log_error("As a workaround, try running the build again - the issue may be transient.");
            
            die "Queue management bug detected - completed node found in ready queue. See error log for debug info.\n";
        }
        
        log_debug("phase3_actual_execution: executing node " . $node->name);
        
        # Execute the node based on mode
        my $new_status = $self->_execute_node($node);
        
        # Update status using transition function to handle notifications
        if ($BuildUtils::VERBOSITY_LEVEL >= 3) {
            log_debug("phase3_actual_execution: setting node " . $node->name . " status to: " . $new_status);
        }
        $self->_transition_node($node, $new_status);
        
        # Process notifications to dependent nodes - direct access, no registry scan needed
        $self->_log_notifications($node);
        
        # Remove the completed node from ready queue using helper function
        remove_from_ready_queue($node);
        
        $nodes_executed++;
    }
    
    log_debug("phase3_actual_execution: executed $nodes_executed nodes");
    return $nodes_executed;
}

# --- Private Helper Methods ---

sub _execute_node {
    my ($self, $node) = @_;
    my $is_validate = $self->is_validate;
    my $is_dry_run = $self->is_dry_run;
    my $build_session_dir = $self->build_session_dir;
    
    my $new_status;
    
    if ($is_validate) {
        # Log validate mode to command log
        $self->_log_command_execution($node, "(VALIDATE - would execute)", "SUCCESS (validate mode)");
        $new_status = 'validate';
        log_debug("VALIDATE: Would execute " . $node->name);
    } elsif ($is_dry_run) {
        # Log dry-run mode to command log
        $self->_log_command_execution($node, "(DRY-RUN - would execute)", "SUCCESS (dry-run mode)");
        $new_status = 'dry-run';
        log_debug("DRY-RUN: Would execute " . $node->name);
    } else {
        # Real execution - actually execute the node
        my $command = $node->command // $node->build_command;
        if ($command) {
            # Get node args and expand command
            my $node_args = $node->get_args || {};
            my $expanded_cmd = expand_command_args($command, $node_args);
            
            log_info("Executing: " . $node->name);
            log_debug("Executing node " . $node->name . " with expanded command: $expanded_cmd");
            
            # Always log command output to files, then show in terminal based on verbosity
            my $log_file = "$build_session_dir/" . $self->_sanitize_log_name($node->name) . ".log";
            
            # Log every command execution to a comprehensive command log
            my $timestamp = localtime();
            $self->_log_command_execution($node, $expanded_cmd, undef, $log_file);
            
            # NOTE: Commands are executed via shell by design - they come from trusted build 
            # configuration files authored by the user. This is intentional as build systems 
            # require shell command execution capabilities. The expand_command_args function
            # only expands ${variable} placeholders with values from the build config.
            my $result;
            if ($BuildUtils::VERBOSITY_LEVEL == 0) {
                # Quiet mode: redirect all output to log files only
                $result = system("$expanded_cmd > $log_file 2>&1");
            } else {
                # Normal/verbose/debug mode: log to file AND show in terminal
                $result = system("bash -c '($expanded_cmd) 2>&1 | tee $log_file; exit \${PIPESTATUS[0]}'");
            }
            
            # Log command result
            if ($result == 0) {
                $self->_log_command_result($node, "SUCCESS (exit code: 0)");
                $new_status = 'done';
                log_info("Completed: " . $node->name);
                log_debug("Node " . $node->name . " completed successfully");
            } else {
                $self->_log_command_result($node, "FAILED (exit code: " . ($result >> 8) . ")");
                $new_status = 'failed';
                log_error("Node " . $node->name . " failed with exit code: " . ($result >> 8));
                # Remove failed node from groups_ready queue
                remove_from_groups_ready($node);
            }
        } else {
            # No command to execute, mark as done
            $self->_log_command_execution($node, "(NO COMMAND - marking as done)", "SUCCESS (no command to execute)");
            $new_status = 'done';
            log_debug("Node " . $node->name . " has no command, marking as done");
        }
    }
    
    return $new_status;
}

sub _transition_node {
    my ($self, $node, $new_status) = @_;
    my $status_manager = $self->status_manager;
    my $registry = $self->registry;
    
    # Use callback if provided, otherwise use internal implementation
    if ($self->{transition_node_callback}) {
        $self->{transition_node_callback}->($node, $new_status, $status_manager->{status}, $registry);
    } else {
        # Internal implementation matching build.pl's transition_node_buildnode
        log_debug("_transition_node called for node: " . ($node ? $node->name : 'undefined') . ", new_status: $new_status");
        
        $status_manager->set_status($node, $new_status);
        
        # Clean up blocked_by relationships when node completes
        if ($new_status eq 'done' || $new_status eq 'skipped' || $new_status eq 'failed') {
            if ($node && $node->can('get_blocked_nodes')) {
                my @blocked_nodes = $node->get_blocked_nodes();
                for my $blocked_key (@blocked_nodes) {
                    my $blocked_node = $registry->get_node_by_key($blocked_key);
                    if ($blocked_node) {
                        $blocked_node->remove_blocker($node);
                        log_debug("Removed blocker " . $node->name . " from " . $blocked_node->name);
                    }
                }
            }
        }
        
        # Process conditional notifications using the new array-based system
        $self->_process_notifications_for_transition($node, $new_status);
    }
}

sub _process_notifications_for_transition {
    my ($self, $node, $new_status) = @_;
    
    # Process unconditional notifications
    if ($node && $node->can('get_notifies')) {
        my @notify_targets = @{ $node->get_notifies() || [] };
        log_debug("_transition_node: " . $node->name . " has " . scalar(@notify_targets) . " unconditional notification targets");
        for my $target_node (@notify_targets) {
            if ($target_node) {
                log_debug("_transition_node: " . $node->name . " completed, sending unconditional notification to " . $target_node->name);
            }
        }
    }

    # Process success notifications
    if ($node && $node->can('get_notifies_on_success')) {
        my @notify_targets = @{ $node->get_notifies_on_success() || [] };
        log_debug("_transition_node: " . $node->name . " has " . scalar(@notify_targets) . " success notification targets");
        for my $target_node (@notify_targets) {
            if ($target_node) {
                if (is_successful_completion_status($new_status)) {
                    log_debug("_transition_node: " . $node->name . " succeeded, updating success_notify for " . $target_node->name);
                    $target_node->update_success_notify($node, 1);  # Mark as true
                } else {
                    log_debug("_transition_node: " . $node->name . " failed, updating success_notify for " . $target_node->name);
                    $target_node->update_success_notify($node, 0);  # Mark as false
                }
            }
        }
    }

    # Process failure notifications
    if ($node && $node->can('get_notifies_on_failure')) {
        my @notify_targets = @{ $node->get_notifies_on_failure() || [] };
        log_debug("_transition_node: " . $node->name . " has " . scalar(@notify_targets) . " failure notification targets");
        for my $target_node (@notify_targets) {
            if ($target_node) {
                if ($new_status eq 'failed') {
                    log_debug("_transition_node: " . $node->name . " failed, updating failure_notify for " . $target_node->name);
                    $target_node->update_failure_notify($node, 1);  # Mark as true
                } else {
                    log_debug("_transition_node: " . $node->name . " succeeded, updating failure_notify for " . $target_node->name);
                    $target_node->update_failure_notify($node, 0);  # Mark as false
                }
            }
        }
    }
}

sub _check_notifications_succeeded {
    my ($self, $node) = @_;
    my $status_manager = $self->status_manager;
    
    # Use callback if provided, otherwise use internal implementation
    if ($self->{check_notifications_callback}) {
        return $self->{check_notifications_callback}->($node, $status_manager->{status});
    }
    
    # Internal implementation matching build.pl's check_notifications_succeeded_buildnode
    if ($node->conditional) {
        my $success_state = $node->all_success_conditions_met;
        my $failure_state = $node->all_failure_conditions_met;
        
        # Debug output
        my $success_array = $node->success_notify;
        my $failure_array = $node->failure_notify;
        log_debug("Node " . $node->name . " conditional check:");
        log_debug("  success_notify: " . scalar(@$success_array) . " entries");
        log_debug("  failure_notify: " . scalar(@$failure_array) . " entries");
        log_debug("  success_state: " . ($success_state == 1 ? "met" : $success_state == 0 ? "not-met" : "not-run"));
        log_debug("  failure_state: " . ($failure_state == 1 ? "met" : $failure_state == 0 ? "not-met" : "not-run"));
        
        my $all_notifications_complete = ($success_state != -1) && ($failure_state != -1);
        my $conditions_met = ($success_state == 1) || ($failure_state == 1);
        
        log_debug("  all_notifications_complete: " . ($all_notifications_complete ? "true" : "false"));
        log_debug("  conditions_met: " . ($conditions_met ? "true" : "false"));
        
        return $all_notifications_complete && $conditions_met;
    }
    
    # Fallback to old system for non-conditional nodes
    my @notifiers = $node->get_notified_by;
    for my $notifier (@notifiers) {
        my $notifier_status = $status_manager->get_status($notifier);
        return 0 unless is_successful_completion_status($notifier_status);
    }
    return 1;
}

sub _sanitize_log_name {
    my ($self, $name) = @_;
    
    # Use callback if provided
    if ($self->{sanitize_log_name_callback}) {
        return $self->{sanitize_log_name_callback}->($name);
    }
    
    # Internal implementation
    my $safe = $name;
    $safe =~ s/[^a-zA-Z0-9._-]/_/g;
    return $safe;
}

sub _log_command_execution {
    my ($self, $node, $command, $result, $log_file) = @_;
    my $build_session_dir = $self->build_session_dir;
    my $command_log_file = "$build_session_dir/COMMAND_EXECUTION.log";
    my $timestamp = localtime();
    my $node_name = $node->name;
    
    # Ensure directory exists
    if (!-d $build_session_dir) {
        require File::Path;
        File::Path::make_path($build_session_dir);
    }
    
    open(my $cmd_log, '>>', $command_log_file) or do {
        log_error("Cannot open command log: $!");
        return;
    };
    print $cmd_log "[$timestamp] EXECUTING: $node_name\n";
    print $cmd_log "[$timestamp] COMMAND: $command\n";
    print $cmd_log "[$timestamp] LOG_FILE: $log_file\n" if $log_file;
    print $cmd_log "[$timestamp] RESULT: $result\n" if $result;
    print $cmd_log "-" x 80 . "\n";
    close($cmd_log);
}

sub _log_command_result {
    my ($self, $node, $result) = @_;
    my $build_session_dir = $self->build_session_dir;
    my $command_log_file = "$build_session_dir/COMMAND_EXECUTION.log";
    my $timestamp = localtime();
    
    open(my $result_log, '>>', $command_log_file) or do {
        log_error("Cannot open command log: $!");
        return;
    };
    print $result_log "[$timestamp] RESULT: $result\n";
    close($result_log);
}

sub _log_notifications {
    my ($self, $node) = @_;
    
    if ($node->can('get_notifies')) {
        my @unconditional = @{ $node->get_notifies() || [] };
        if (@unconditional) {
            log_debug("Processing unconditional notifications from " . $node->name . " to " . 
                     join(", ", map { $_->name } @unconditional));
        }
    }
    
    if ($node->can('get_notifies_on_success')) {
        my @success = @{ $node->get_notifies_on_success() || [] };
        if (@success) {
            log_debug("Processing success notifications from " . $node->name . " to " . 
                     join(", ", map { $_->name } @success));
        }
    }
    
    if ($node->can('get_notifies_on_failure')) {
        my @failure = @{ $node->get_notifies_on_failure() || [] };
        if (@failure) {
            log_debug("Processing failure notifications from " . $node->name . " to " . 
                     join(", ", map { $_->name } @failure));
        }
    }
}

sub _log_queue_states {
    my ($self, $iterations) = @_;
    my $status_manager = $self->status_manager;
    
    log_debug("=== AFTER ALL PHASES ===");
    log_debug("Queue states after iteration $iterations:");
    log_debug("  RPP size: " . get_ready_pending_parent_size());
    log_debug("  Ready size: " . get_ready_queue_size());
    log_debug("  GR size: " . get_groups_ready_size());
    
    # Show what's in each queue
    if (get_ready_pending_parent_size() > 0) {
        log_debug("  RPP nodes remaining:");
        for my $i (0 .. min(4, get_ready_pending_parent_size() - 1)) {
            my $node = $main::READY_PENDING_PARENT_NODES[$i];
            my $status = $status_manager->get_status($node);
            my $in_gr = is_node_in_groups_ready($node) ? "YES" : "NO";
            log_debug("    " . $node->name . " (status: $status, in GR: $in_gr)");
        }
    }
    
    if (get_ready_queue_size() > 0) {
        log_debug("  Ready queue nodes:");
        for my $i (0 .. min(4, get_ready_queue_size() - 1)) {
            my $node = $main::READY_QUEUE_NODES[$i];
            my $status = $status_manager->get_status($node);
            log_debug("    " . $node->name . " (status: $status)");
        }
    }
    
    # Loop condition check
    log_debug("Loop condition check:");
    log_debug("  Ready queue size > 0: " . (get_ready_queue_size() > 0 ? "YES" : "NO"));
    log_debug("  RPP size > 0: " . (get_ready_pending_parent_size() > 0 ? "YES" : "NO"));
    log_debug("  Loop should continue: " . ((get_ready_queue_size() > 0 || get_ready_pending_parent_size() > 0) ? "YES" : "NO"));
}

sub _log_no_progress_details {
    my ($self) = @_;
    my $status_manager = $self->status_manager;
    
    log_debug("DEBUG: Queue states when no progress:");
    log_debug("  RPP size: " . get_ready_pending_parent_size());
    log_debug("  Ready size: " . get_ready_queue_size());
    log_debug("  GR size: " . get_groups_ready_size());
    
    # Show all RPP nodes to understand what's blocking
    if (get_ready_pending_parent_size() > 0) {
        log_debug("  All RPP nodes remaining:");
        for my $i (0 .. get_ready_pending_parent_size() - 1) {
            my $node = $main::READY_PENDING_PARENT_NODES[$i];
            my $status = $status_manager->get_status($node);
            my $in_gr = is_node_in_groups_ready($node) ? "YES" : "NO";
            log_debug("    " . $node->name . " (status: $status, in GR: $in_gr)");
            
            # If node is in GR but not ready, check why
            if ($in_gr eq "YES" && $status eq "pending") {
                log_debug("      Node is in GR but still pending - checking parent coordination");
                if ($node->has_any_parents()) {
                    my $parents = $node->get_parents;
                    for my $parent (@$parents) {
                        my $parent_in_gr = is_node_in_groups_ready($parent) ? "YES" : "NO";
                        my $parent_status = $status_manager->get_status($parent);
                        log_debug("        Parent " . $parent->name . " (in GR: $parent_in_gr, status: $parent_status)");
                        
                        # Check dependency group status
                        if ($parent->can('children') && $parent->children && ref($parent->children) eq 'ARRAY') {
                            for my $child (@{$parent->children}) {
                                if (($child->get_child_order // 0) == 0) {  # dependency group (child_id 0)
                                    my $dep_group_status = $status_manager->get_status($child);
                                    log_debug("          Dependency group " . $child->name . " status: $dep_group_status");
                                }
                            }
                        }
                    }
                } else {
                    log_debug("      Node has no parents - should be ready");
                }
            }
        }
    }
}

1;

__END__

=head1 NAME

BuildExecutionEngine - Encapsulates the three-phase execution loop for the build system

=head1 AUTHOR

Distributed Build System (DBS)

=head1 LICENSE

This module is part of the Distributed Build System (DBS).

=cut
