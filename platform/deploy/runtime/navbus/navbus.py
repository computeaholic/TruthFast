from .guards.route_guard import NavBusRouteGuard


class NavBus:
    def __init__(self):
        self.route_guard = NavBusRouteGuard()
        # ...existing code...

    def route(self, spiffe_id, target, payload):
        if not self.route_guard.authorize_route(spiffe_id, target):
            raise PermissionError("Route denied by NavBusRouteGuard")
        # ...existing code...
