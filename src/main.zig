pub const std_os_options: std.Options.OperatingSystem = horizon.default_std_os_options;
pub const panic = horizon.debug.simple_errdisp_panic;
pub const zitrus_options: zitrus.Options = .{
    .stack_size = switch (@import("builtin").mode) {
        else => 16 * 1024, // We'll stack overflow otherwise
        .ReleaseSafe, .ReleaseSmall, .ReleaseFast => null, // Use the kernel-provided stack (4096 bytes in this case)
    },
};

pub fn main() void {
    const srv = assertResult(ServiceManager.openWithResult());
    defer srv.close();

    const tls = horizon.tls.get();
    const ipc = &tls.ipc;

    assertResult(srv.sendWithResult(.RegisterClient, .{}, .{}));

    var session_port_mapping_buffer: [service_names.len]u32 = undefined;
    var session_port_mapping: std.ArrayList(u32) = .initBuffer(&session_port_mapping_buffer);

    var handles: [1 + service_names.len * 2]horizon.Synchronization = undefined;
    var ports: std.ArrayList(Port.Server) = .initBuffer(@ptrCast(handles[1..][0..service_names.len]));
    defer for (ports.items) |port| port.close();
    var sessions: std.ArrayList(Session.Server) = .initBuffer(@ptrCast(handles[1 + service_names.len ..][0..service_names.len]));
    defer for (sessions.items) |remote| remote.close();

    handles[0] = @bitCast(assertResult(srv.sendWithResult(.EnableNotification, {}, .{})));
    defer handles[0].close();

    for (service_names) |name| ports.appendAssumeCapacity(assertResult(srv.sendWithResult(.RegisterService, .init(name, 1), .{})).wrapped);
    defer for (service_names) |name| assertResult(srv.sendWithResult(.UnregisterService, .embedded(name), .{}));

    var stop = false;
    var remote_reply: Session.Server = .none;
    var remote_reply_idx: ?u32 = null;
    while (true) {
        if (remote_reply == Session.Server.none) {
            if (stop and sessions.items.len == 0) break;

            ipc.packed_command.header = .none;
        }

        const res = horizon.replyAndReceive(handles[0 .. 1 + ports.items.len + sessions.items.len], remote_reply);
        const last_remote_reply_idx = remote_reply_idx;
        remote_reply, remote_reply_idx = .{ .none, null };

        const idx: usize = if (res.value < 0)
            (if (last_remote_reply_idx) |idx| idx else {
                assertCode(.failure);
                unreachable;
            })
        else
            @intCast(res.value);

        if (!res.code.isSuccess()) switch (res.code) {
            .os_session_closed_by_remote => {
                const closed_remote_idx = idx - remotes_begin;

                _ = session_port_mapping.swapRemove(closed_remote_idx);
                sessions.swapRemove(closed_remote_idx).close();
                continue;
            },
            else => assertCode(res.code),
        };

        switch (idx) {
            0 => switch (assertResult(srv.sendWithResult(.ReceiveNotification, {}, .{}))) {
                .must_terminate => stop = true,
                else => {},
            },
            ports_begin...ports_end => {
                const port_idx = idx - ports_begin;
                const port = ports.items[port_idx];

                sessions.appendAssumeCapacity(assertResult(horizon.acceptSession(port)));
                session_port_mapping.appendAssumeCapacity(port_idx);
            },
            remotes_begin...remotes_end => {
                remote_reply_idx = idx;
                const session_idx = idx - remotes_begin;
                remote_reply = sessions.items[session_idx];

                const port_idx = session_port_mapping.items[session_idx];

                switch (port_idx) {
                    0 => if (ipc.readRequestId(pdns.Sleep.command.Id)) |id| switch (id) {
                        .get_wake_status => if (ipc.readRequest(pdns.Sleep.command.GetWakeStatus)) |_| ipc.writeResponse(pdns.Sleep.command.GetWakeStatus, .of(
                            .success,
                            .{
                                .enabled = pdn.sleep.wake_enable,
                                .reason = pdn.sleep.wake_reason,
                            },
                        )),
                        .configure_wake => if (ipc.readRequest(pdns.Sleep.command.ConfigureWake)) |req| ipc.writeResponse(pdns.Sleep.command.ConfigureWake, blk: {
                            pdn.sleep.wake_reason = @bitCast(req.enable.int() & req.acknowledge.int());
                            pdn.sleep.wake_enable = req.enable;
                            pdn.sleep.wake_reason = @bitCast(~req.enable.int() & req.acknowledge.int());
                            break :blk .of(.success, {});
                        }),
                        .acknowledge_wake => if (ipc.readRequest(pdns.Sleep.command.AcknowledgeWake)) |req| ipc.writeResponse(pdns.Sleep.command.AcknowledgeWake, .of(blk: {
                            pdn.sleep.wake_reason = req.acknowledge;
                            break :blk .success;
                        }, {})),
                    },
                    1 => if (ipc.readRequestId(pdns.I2s.command.Id)) |id| switch (id) {
                        .set_enabled_1 => if (ipc.readRequest(pdns.I2s.command.SetEnabled1)) |req| ipc.writeResponse(pdns.I2s.command.SetEnabled1, blk: {
                            var i2s = pdn.clock.i2s;
                            i2s.i2s1 = req;
                            pdn.clock.i2s = i2s;
                            break :blk .of(.success, {});
                        }),
                        .set_enabled_2 => if (ipc.readRequest(pdns.I2s.command.SetEnabled2)) |req| ipc.writeResponse(pdns.I2s.command.SetEnabled2, blk: {
                            var i2s = pdn.clock.i2s;
                            i2s.i2s2 = req;
                            pdn.clock.i2s = i2s;
                            break :blk .of(.success, {});
                        }),
                    },
                    2 => if (ipc.readRequestId(pdns.Gpu.command.Id)) |id| switch (id) {
                        .control => if (ipc.readRequest(pdns.Gpu.command.Control)) |req| ipc.writeResponse(pdns.Gpu.command.Control, blk: {
                            if ((req.reset or req.reset_registers) and !req.enable) break :blk .of(.pdn_invalid_arg, {});

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

                            pdn.clock.gpu = gpu;

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

                                pdn.clock.gpu = gpu;
                            }

                            break :blk .of(.success, {});
                        }),
                    },
                    3 => if (ipc.readRequestId(pdns.Dsp.command.Id)) |id| switch (id) {
                        .control => if (ipc.readRequest(pdns.Dsp.command.Control)) |req| ipc.writeResponse(pdns.Dsp.command.Control, blk: {
                            if (req.reset_registers and !req.enable) break :blk .of(.pdn_invalid_arg, {});

                            var dsp: hardware.pdn.Clock.Dsp = .{
                                .enable = req.enable,
                                .reset = .reset(req.reset),
                            };

                            pdn.clock.dsp = dsp;
                            if (req.reset and req.reset_registers) {
                                spin(48);

                                dsp = .{ .reset = .enabled, .enable = req.enable };
                                pdn.clock.dsp = dsp;
                            }

                            break :blk .of(.success, {});
                        }),
                    },
                    4 => if (ipc.readRequestId(pdns.Camera.command.Id)) |id| switch (id) {
                        .set_enabled => if (ipc.readRequest(pdns.Camera.command.SetEnabled)) |req| ipc.writeResponse(pdns.Camera.command.SetEnabled, blk: {
                            const camera: hardware.pdn.Clock.Enable = .{ .enable = req };
                            pdn.clock.camera = camera;
                            break :blk .of(.success, {});
                        }),
                        .is_enabled => if (ipc.readRequest(pdns.Camera.command.IsEnabled)) |_| ipc.writeResponse(pdns.Camera.command.IsEnabled, .of(
                            .success,
                            pdn.clock.camera.enable,
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

const assertResult = ErrorDisplayManager.assertResult;
const assertCode = ErrorDisplayManager.assertCode;

const ports_begin = 1;
const ports_end = 1 + service_names.len - 1;

const remotes_begin = 1 + service_names.len;
const remotes_end = 1 + (service_names.len * 2) - 1;

const service_names: []const []const u8 = &.{ "pdn:s", "pdn:i", "pdn:g", "pdn:d", "pdn:c" };

const std = @import("std");
const zitrus = @import("zitrus");

const hardware = zitrus.hardware;

const horizon = zitrus.horizon;
const ServiceManager = horizon.ServiceManager;
const ErrorDisplayManager = horizon.ErrorDisplayManager;

const Port = horizon.Port;
const Session = horizon.Session;
const Code = horizon.result.Code;

const pdns = horizon.services.pdn;
const pdn = horizon.memory.pdn;
