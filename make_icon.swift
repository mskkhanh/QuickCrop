import Cocoa

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }
ctx.setShouldAntialias(true)

let outer = NSBezierPath(roundedRect: NSRect(x:64,y:64,width:896,height:896), xRadius:210, yRadius:210)
let bg = NSGradient(colorsAndLocations:
    (NSColor(calibratedRed:0.055, green:0.065, blue:0.085, alpha:1), 0.0),
    (NSColor(calibratedRed:0.16, green:0.18, blue:0.23, alpha:1), 1.0)
)!
bg.draw(in: outer, angle:-55)

let photoRect = NSRect(x:235,y:275,width:554,height:430)
let photo = NSBezierPath(roundedRect:photoRect, xRadius:70, yRadius:70)
let photoGradient = NSGradient(colorsAndLocations:
    (NSColor(calibratedRed:0.25, green:0.78, blue:0.86, alpha:1),0.0),
    (NSColor(calibratedRed:0.37, green:0.40, blue:0.91, alpha:1),1.0)
)!
photoGradient.draw(in:photo, angle:-35)

NSGraphicsContext.saveGraphicsState()
photo.addClip()
let mountainBack = NSBezierPath()
mountainBack.move(to:NSPoint(x:220,y:300))
mountainBack.line(to:NSPoint(x:470,y:555))
mountainBack.line(to:NSPoint(x:610,y:395))
mountainBack.line(to:NSPoint(x:815,y:300))
mountainBack.close()
NSColor(calibratedWhite:1, alpha:0.42).setFill()
mountainBack.fill()

let mountainFront = NSBezierPath()
mountainFront.move(to:NSPoint(x:280,y:275))
mountainFront.line(to:NSPoint(x:545,y:520))
mountainFront.line(to:NSPoint(x:805,y:275))
mountainFront.close()
NSColor(calibratedWhite:0.08, alpha:0.28).setFill()
mountainFront.fill()

NSColor(calibratedWhite:1, alpha:0.88).setFill()
NSBezierPath(ovalIn:NSRect(x:625,y:545,width:78,height:78)).fill()
NSGraphicsContext.restoreGraphicsState()

func strokeLine(_ a:NSPoint,_ b:NSPoint) {
    let p = NSBezierPath()
    p.move(to:a); p.line(to:b)
    p.lineWidth = 30
    p.lineCapStyle = .round
    NSColor.white.setStroke()
    p.stroke()
}

let l:CGFloat = 145
let inset:CGFloat = 175
strokeLine(NSPoint(x:inset,y:1024-inset-l), NSPoint(x:inset,y:1024-inset))
strokeLine(NSPoint(x:inset,y:1024-inset), NSPoint(x:inset+l,y:1024-inset))
strokeLine(NSPoint(x:1024-inset-l,y:1024-inset), NSPoint(x:1024-inset,y:1024-inset))
strokeLine(NSPoint(x:1024-inset,y:1024-inset), NSPoint(x:1024-inset,y:1024-inset-l))
strokeLine(NSPoint(x:inset,y:inset+l), NSPoint(x:inset,y:inset))
strokeLine(NSPoint(x:inset,y:inset), NSPoint(x:inset+l,y:inset))
strokeLine(NSPoint(x:1024-inset-l,y:inset), NSPoint(x:1024-inset,y:inset))
strokeLine(NSPoint(x:1024-inset,y:inset), NSPoint(x:1024-inset,y:inset+l))

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data:tiff),
      let png = rep.representation(using:.png, properties:[:]) else { exit(2) }
try png.write(to:URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("QuickCrop-icon-1024.png"))
