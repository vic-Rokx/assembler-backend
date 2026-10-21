//! Playground code that uses every API the system prompt names outside its
//! examples, so a vapor pin that breaks one fails `zig build test`.
const std = @import("std");
const Vapor = @import("vapor");
const Color = Vapor.Types.Color;

pub const std_options = std.Options{ .logFn = Vapor.lib.log };

var name: []const u8 = "";
var age: i32 = 0;
var height: f32 = 0;
var secret: []const u8 = "";
var email: []const u8 = "";
var hovered = false;
var users: ?*Vapor.Fetch.Request = null;
var saved_body: []const u8 = "";

export fn init() void {
    Vapor.init(.{});
    Vapor.Page(.{ .route = "/" }, render, null);
    Vapor.Page(.{ .route = "/users/:id" }, userPage, null);
    const request = Vapor.fetch("/api/users", .{});
    request.handle(onUsers, .{});
    users = request;
    _ = Vapor.fetch("/api/users", .{ .method = .POST, .body = "{}", .body_type = .json });
}

fn onUsers(result: Vapor.Fetch.Result) void {
    switch (result) {
        .ok => |response| {
            if (response.status == 200) saved_body = Vapor.persist.fmt("{s}", .{response.body});
        },
        .err => |err| std.log.err("{s}", .{err.message}),
    }
}

fn clicked(id: u32, event: *Vapor.Event) void {
    _ = id;
    if (event.metaKey() or event.shiftKey()) event.preventDefault();
}

fn hover(event: *Vapor.Event) void {
    _ = event;
    hovered = !hovered;
}

fn changed(event: *Vapor.Event) void {
    name = Vapor.persist.dupe(event.text());
}

fn submitted(event: *Vapor.Event) void {
    event.preventDefault();
    Vapor.navigate("/users/1");
}

fn render() void {
    Vapor.Box().size(.squarePx(40)).children({});
    Vapor.Section().width(.px(320)).height(.vp(100)).maxWidth(.px(640)).minHeight(.px(10)).children({
        Vapor.Box().width(.percent(50)).direction(.row).wrap(.wrap).layout(.x_between_center).children({
            Vapor.Box().layout(.top_center).padding(.{ .top = 8, .left = 12 }).pt(8).pl(12).padX(16).padY(8).children({});
            Vapor.Box().layout(.x_even).margin(.all(4)).mt(8).children({});
        });
        Vapor.List().children({
            Vapor.ListItem().children({
                Vapor.Link(.{ .url = "/users/2" }).children({
                    Vapor.Text("user").fontWeight(700).fontFamily("Inter").textDecoration(.underline).end();
                });
            });
        });
        Vapor.Form(submitted, .{}).children({
            Vapor.Label("Name").end();
            Vapor.TextField(.string).bind(&name).onChange(changed, .{}).end();
            Vapor.TextField(.int).bind(&age).end();
            Vapor.TextField(.float).bind(&height).end();
            Vapor.TextField(.password).bind(&secret).end();
            Vapor.TextField(.email).bind(&email).end();
            Vapor.TextArea().bind(&name).end();
        });
        Vapor.Table().children({
            Vapor.TableRow().children({
                Vapor.TableCell().children({
                    Vapor.Code("const x = 1;").end();
                });
            });
        });
        Vapor.Box()
            .onEvent(.click, clicked, .{@as(u32, 1)})
            .onHover(hover, .{})
            .onLeave(hover, .{})
            .hidden(hovered)
            .background(.hex("#FF5500"))
            .border(.thin(.rgb(255, 85, 0)))
            .opacity(0.8)
            .duration(150)
            .inlineStyle("user-select: none;", .{})
            .children({
            Vapor.Image(.{ .src = "/logo.png", .alt = "logo" }).end();
            Vapor.Spacer(8).end();
            Vapor.Divider(1).end();
        });
        Vapor.Box().border(.bottom(1, .black)).background(.transparentize(Color.black, 0.5)).textColor(.rgba(0, 0, 0, 0.5)).children({});
        Vapor.Box().background(.transparent).border(.{ .radius = .all(8) }).children({});
        if (users) |request| switch (request.state()) {
            .idle, .loading => Vapor.Text("Loading").end(),
            .ok => Vapor.Text(saved_body).end(),
            .err => Vapor.Text("Failed").end(),
        };
        Vapor.Text(@as(u32, 42)).end();
    });
}

fn userPage() void {
    Vapor.Text(Vapor.routeParam("id") orelse "none").end();
}
