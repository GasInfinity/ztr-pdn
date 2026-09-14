pub const std_os_options: std.Options.OperatingSystem = horizon.default_std_os_options;
pub const panic = horizon.debug.simple_errdisp_panic;
pub const zitrus_options: zitrus.Options = .{
    .stack_size = switch (@import("builtin").mode) {
        else => 16 * 1024, // We'll stack overflow otherwise
        .ReleaseSafe, .ReleaseSmall, .ReleaseFast => null, // Use the kernel-provided stack (4096 bytes in this case)
    },
};

pub fn main() !void {
    const srv: horizon.ServiceManager = try .open();
    defer srv.close();

    try srv.sendRegisterClient();

    var session_port_mapping_buffer: [service_names.len]u32 = undefined;
    var session_port_mapping: std.ArrayList(u32) = .initBuffer(&session_port_mapping_buffer);

    var handles: [1 + service_names.len * 2]horizon.Synchronization = undefined;
    var ports: std.ArrayList(Port.Server) = .initBuffer(@ptrCast(handles[1..][0..service_names.len]));
    defer for (ports.items) |port| port.close();
    var sessions: std.ArrayList(Session.Server) = .initBuffer(@ptrCast(handles[1 + service_names.len..][0..service_names.len]));
    defer for (sessions.items) |remote| remote.close();

    handles[0] = @bitCast(try srv.sendEnableNotification());
    defer handles[0].close();

    for (service_names) |name| ports.appendAssumeCapacity(try srv.sendRegisterService(name, 1));
    defer for (service_names) |name| srv.sendUnregisterService(name) catch |err| @panic(@errorName(err));

    const tls = horizon.tls.get();
    const ipc = &tls.ipc;

    var stop = false;
    var remote_reply: Session.Server = .none;
    var remote_reply_idx: ?u32 = null;
    while (true) {
        if (remote_reply == Session.Server.none) {
            if (stop and sessions.items.len == 0) break; 

            ipc.packed_command.header = .none;
        }

        const res = horizon.replyAndReceive(handles[0..1 + ports.items.len + sessions.items.len], remote_reply);
        const last_remote_reply_idx = remote_reply_idx;
        remote_reply, remote_reply_idx = .{ .none, null };

        const idx: usize = if (res.value < 0) 
            (if (last_remote_reply_idx) |idx| idx else return error.Unexpected)
        else @intCast(res.value);

        if (!res.code.isSuccess()) switch (res.code) {
            .os_session_closed_by_remote => {
                const closed_remote_idx = idx - remotes_begin;

                _ = session_port_mapping.swapRemove(closed_remote_idx);
                sessions.swapRemove(closed_remote_idx).close();
                continue;
            },
            else => return error.Unexpected,
        };

        switch (idx) {
            0 => switch (try srv.sendReceiveNotification()) {
                .must_terminate => stop = true,
                else => {},
            },
            ports_begin...ports_end => {
                const port_idx = idx - ports_begin; 
                const port = ports.items[port_idx];

                sessions.appendAssumeCapacity(try port.accept());
                session_port_mapping.appendAssumeCapacity(port_idx);
            },
            remotes_begin...remotes_end => {
                remote_reply_idx = idx;
                const session_idx = idx - remotes_begin;
                remote_reply = sessions.items[session_idx];
                
                const port_idx = session_port_mapping.items[session_idx];

                switch (port_idx) {
                    0 => if (ipc.readRequestId(pdn.Sleep.command.Id)) |id| switch (id) {
                        .get_wake_status => ipc.writeResponse(pdn.Sleep.command.GetWakeStatus, .of(
                            .success,
                            .{
                                .enabled = pdn_registers.sleep.wake_enable,
                                .reason = pdn_registers.sleep.wake_reason,
                            },
                        )),
                        .configure_wake => ipc.writeResponse(pdn.Sleep.command.ConfigureWake, blk: {
                            const req = ipc.readRequest(pdn.Sleep.command.ConfigureWake) catch break :blk .of(.os_invalid_ipc_parameters, .{});
                            pdn_registers.sleep.wake_reason = @bitCast(req.enable.int() & req.acknowledge.int());
                            pdn_registers.sleep.wake_enable = req.enable;
                            pdn_registers.sleep.wake_reason = @bitCast(~req.enable.int() & req.acknowledge.int());
                            break :blk .of(.success, .{});
                        }),
                        .acknowledge_wake => ipc.writeResponse(pdn.Sleep.command.AcknowledgeWake, blk: {
                            const req = ipc.readRequest(pdn.Sleep.command.AcknowledgeWake) catch break :blk .of(.os_invalid_ipc_parameters, .{});
                            pdn_registers.sleep.wake_reason = req.acknowledge;
                            break :blk .of(.success, .{});
                        }),
                    },
                    1 => if (ipc.readRequestId(pdn.I2s.command.Id)) |id| switch (id) {
                        .control_1 => ipc.writeResponse(pdn.I2s.command.Control1, blk: {
                            const req = ipc.readRequest(pdn.I2s.command.Control1) catch break :blk .of(.os_invalid_ipc_parameters, .{});
                            var i2s = pdn_registers.clock.i2s;
                            i2s.i2s1 = req.enable;
                            pdn_registers.clock.i2s = i2s;
                            break :blk .of(.success, .{});
                        }),
                        .control_2 => ipc.writeResponse(pdn.I2s.command.Control2, blk: {
                            const req = ipc.readRequest(pdn.I2s.command.Control2) catch break :blk .of(.os_invalid_ipc_parameters, .{});
                            var i2s = pdn_registers.clock.i2s;
                            i2s.i2s2 = req.enable;
                            pdn_registers.clock.i2s = i2s;
                            break :blk .of(.success, .{});
                        }),
                    },
                    2 => if (ipc.readRequestId(pdn.Gpu.command.Id)) |id| switch (id) {
                        .control => ipc.writeResponse(pdn.Gpu.command.Control, blk: {
                            const req = ipc.readRequest(pdn.Gpu.command.Control) catch break :blk .of(.os_invalid_ipc_parameters, .{});
                            if ((req.reset or req.reset_registers) and !req.enable) break :blk .of(.pdn_invalid_arg, .{});

                            var gpu: hardware.pdn.Clock.Gpu = .{
                                .main = .reset(req.reset),
                                .psc = .reset(req.reset_registers),
                                .geometry_shader = .reset(req.reset_registers),
                                .rasterization = .reset(req.reset_registers),
                                .ppf = .reset(req.reset_registers),
                                .pdc = .reset(req.reset_registers),
                                .pdc_related = .reset(req.reset_registers),
                                .enable = req.enable,
                            };

                            pdn_registers.clock.gpu = gpu;

                            if (req.reset or req.reset_registers) {
                                spin(12);
                                gpu = .{
                                    .main = .enabled,
                                    .psc = .enabled,
                                    .geometry_shader = .enabled,
                                    .rasterization = .enabled,
                                    .ppf = .enabled,
                                    .pdc = .enabled,
                                    .pdc_related = .enabled,
                                    .enable = req.enable,
                                };

                                pdn_registers.clock.gpu = gpu;
                            }

                            break :blk .of(.success, .{});
                        }),
                    },
                    3 => if (ipc.readRequestId(pdn.Dsp.command.Id)) |id| switch (id) {
                        .control => ipc.writeResponse(pdn.Dsp.command.Control, blk: {
                            const req = ipc.readRequest(pdn.Dsp.command.Control) catch break :blk .of(.os_invalid_ipc_parameters, .{});
                            if (req.reset_registers and !req.enable) break :blk .of(.pdn_invalid_arg, .{});

                            var dsp: hardware.pdn.Clock.Dsp = .{
                                .enable = req.enable,
                                .reset = .reset(req.reset),
                            };

                            pdn_registers.clock.dsp = dsp;
                            if (req.reset and req.reset_registers) {
                                spin(48);

                                dsp = .{ .reset = .enabled, .enable = req.enable };
                                pdn_registers.clock.dsp = dsp;
                            }

                            break :blk .of(.success, .{});
                        }),
                    },
                    4 => if (ipc.readRequestId(pdn.Camera.command.Id)) |id| switch (id) {
                        .control => ipc.writeResponse(pdn.Camera.command.Control, blk: {
                            const req = ipc.readRequest(pdn.Camera.command.Control) catch break :blk .of(.os_invalid_ipc_parameters, .{});
                            const camera: hardware.pdn.Clock.Enable = .{ .enable = req.enable };
                            pdn_registers.clock.camera = camera;
                            break :blk .of(.success, .{});
                        }),
                        .is_enabled => ipc.writeResponse(pdn.Camera.command.IsEnabled, .of(
                            .success,
                            .{ .enabled = pdn_registers.clock.camera.enable },
                        )),
                    },
                    else => unreachable,
                }
            },
            else => unreachable,
        }
    }
}

fn spin(amount: usize) void {
    var i = amount;
    while (i > 0) : (i -= 1) std.mem.doNotOptimizeAway(i);
}

const ports_begin = 1;
const ports_end = 1 + service_names.len - 1;

const remotes_begin = 1 + service_names.len;
const remotes_end = 1 + (service_names.len * 2) - 1;

const service_names: []const []const u8 = &.{ "pdn:s", "pdn:i", "pdn:g", "pdn:d", "pdn:c" };

const std = @import("std");
const zitrus = @import("zitrus");

const hardware = zitrus.hardware;

const horizon = zitrus.horizon;
const Port = horizon.Port;
const Session = horizon.Session;
const Code = horizon.result.Code;

const pdn = horizon.services.pdn;
const pdn_registers = horizon.memory.pdn_registers;
