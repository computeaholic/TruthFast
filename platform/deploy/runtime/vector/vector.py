from .guards.vector_guard import VectorGuard


class VectorHandler:
    def __init__(self):
        self.guard = VectorGuard()
        # ...existing code...

    def handle_request(self, spiffe_id, operation, data):
        if not self.guard.authorize(spiffe_id, operation):
            raise PermissionError("Vector operation denied")
        # ...existing code...
