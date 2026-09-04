from .guards.identity_guard import SMPIdentityGuard


class CommandBus:
    def __init__(self):
        self.identity_guard = SMPIdentityGuard()
        self.handlers = {}  # Assume handlers are set up elsewhere

    def dispatch(self, spiffe_id, command, payload):
        self.identity_guard.validate(spiffe_id, command)
        return self.handlers[command](payload)
