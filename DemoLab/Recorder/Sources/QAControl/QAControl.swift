import DemoDriverKit
import AppKit
import Foundation
@main struct UIProbe {
 @MainActor static func main() throws {
  let a=Array(CommandLine.arguments.dropFirst())
  if a.first == "apps" { for app in NSWorkspace.shared.runningApplications { print("\(app.processIdentifier) \(app.bundleIdentifier ?? "-") \(app.localizedName ?? "-")") }; return }
  guard a.count >= 2 else {return}
  if a[0] == "terminate" { NSRunningApplication.runningApplications(withBundleIdentifier:a[1]).first?.terminate(); return }
  if a[0] == "activate" { NSRunningApplication.runningApplications(withBundleIdentifier:a[1]).first?.activate(); return }
  if a[0] == "frame", a.count >= 3 { let f=try NativeInteractionDriver.controlFrame(bundleIdentifier:a[1],identifier:a[2]); print("\(f.minX),\(f.minY),\(f.width),\(f.height)");return }
  if a[0] == "clickoffset", a.count >= 4 {
   guard KeyDriver.isTrusted else {throw DriverError.notTrusted}
   let f=try NativeInteractionDriver.controlFrame(bundleIdentifier:a[1],identifier:a[2]); let p=CGPoint(x:f.midX+Double(a[3])!,y:f.midY)
   for kind in [CGEventType.mouseMoved,.leftMouseDown,.leftMouseUp] {let event=CGEvent(mouseEventSource:nil,mouseType:kind,mouseCursorPosition:p,mouseButton:.left)!;event.flags=[];event.post(tap:.cghidEventTap);Thread.sleep(forTimeInterval:0.1)}
   return
  }
  if a[0] == "hover", a.count >= 3 { try NativeInteractionDriver.hover(bundleIdentifier:a[1],identifier:a[2]);return }
  if a[0] == "snapshot" { print(try NativeInteractionDriver.snapshot(bundleIdentifier:a[1])) }
  if a[0] == "click", a.count >= 3 { try NativeInteractionDriver.click(bundleIdentifier:a[1],identifier:a[2]) }
  if a[0] == "drag", a.count >= 5 {try NativeInteractionDriver.drag(from:CGPoint(x:Double(a[1])!,y:Double(a[2])!),to:CGPoint(x:Double(a[3])!,y:Double(a[4])!))}
 }
}
