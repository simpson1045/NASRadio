class ProgressTracker:
    """Track progress for long-running operations"""

    def __init__(self):
        self.operations = {}

    def start_operation(self, operation_id, total_items, description):
        """Start tracking a new operation"""
        self.operations[operation_id] = {
            "total": total_items,
            "current": 0,
            "description": description,
            "status": "running",
            "message": f"Starting {description}...",
        }

    def update_progress(self, operation_id, current, message=None):
        """Update progress for an operation"""
        if operation_id in self.operations:
            self.operations[operation_id]["current"] = current
            if message:
                self.operations[operation_id]["message"] = message

    def complete_operation(self, operation_id, message="Complete"):
        """Mark operation as complete"""
        if operation_id in self.operations:
            self.operations[operation_id]["status"] = "complete"
            self.operations[operation_id]["message"] = message

    def fail_operation(self, operation_id, message="Failed"):
        """Mark operation as failed"""
        if operation_id in self.operations:
            self.operations[operation_id]["status"] = "failed"
            self.operations[operation_id]["message"] = message

    def get_progress(self, operation_id):
        """Get current progress for an operation"""
        return self.operations.get(operation_id)

    def clear_operation(self, operation_id):
        """Remove operation from tracking"""
        if operation_id in self.operations:
            del self.operations[operation_id]

    def cancel_operation(self, operation_id):
        """Cancel an operation"""
        if operation_id in self.operations:
            self.operations[operation_id]["status"] = "cancelled"
            self.operations[operation_id]["message"] = "Operation cancelled by user"

    def is_cancelled(self, operation_id):
        """Check if an operation has been cancelled"""
        if operation_id in self.operations:
            return self.operations[operation_id].get("status") == "cancelled"
        return False


# Global progress tracker instance
progress_tracker = ProgressTracker()
