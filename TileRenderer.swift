// Original Metro-inspired live music visual. No Microsoft artwork or code is bundled.
import AppKit
import Foundation
import ScriptingBridge
import CoreImage

let width = 1280
let height = 720
let fm = FileManager.default
func writeJSON(_ value: [String:Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(data + Data([10]))
    }
}

func watchMusic() {
    guard let app = SBApplication(bundleIdentifier: "com.apple.Music") else { exit(2) }
    app.timeout = 120
    var last = ""
    repeat {
        autoreleasepool {
            var info: [String:Any] = [:]
            if let track = app.value(forKey: "currentTrack") as? SBObject {
                for key in ["name", "artist", "albumArtist", "album"] {
                    if let value = track.value(forKey: key) as? String { info[key] = value }
                }
            }
            let key = ["name","artist","albumArtist","album"].map { info[$0] as? String ?? "" }.joined(separator: "\u{1f}")
            if key != last && !(info["name"] as? String ?? "").isEmpty {
                last = key
                info["key"] = key
                writeJSON(info)
            }
        }
        if CommandLine.arguments.contains("--once") { break }
        Thread.sleep(forTimeInterval: 0.7)
    } while true
}

func bitmap(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                     colorSpaceName: .deviceRGB, bytesPerRow: w*4, bitsPerPixel: 32)!
}
func save(_ image: NSBitmapImageRep, _ url: URL) {
    if let png = image.representation(using: .png, properties: [:]) {
        try? png.write(to: url, options: .atomic)
    }
}
func drawInto(_ image: NSBitmapImageRep, _ block: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
    NSGraphicsContext.current?.imageInterpolation = .medium
    block()
    NSGraphicsContext.restoreGraphicsState()
}
func font(_ size: CGFloat) -> NSFont {
    NSFont(name: "SegoeUI-Light", size: size) ?? NSFont(name: "HelveticaNeue-Light", size: size)
        ?? NSFont.systemFont(ofSize: size, weight: .light)
}


struct Snapshot {
    var title = "Apple Music", artist = "Surround Stream", album = "", key = "", credit = ""
    var pictures:[String] = []
    var updated = ProcessInfo.processInfo.systemUptime
}
final class Scene {
    let lock = NSLock();var value = Snapshot()
    func update(_ info:[String:Any]) {
        lock.lock();defer { lock.unlock() }
        let key = info["key"] as? String ?? ""
        if key != value.key {
            value.key = key;value.updated = ProcessInfo.processInfo.systemUptime
            value.title = info["name"] as? String ?? "Apple Music"
            value.artist = info["artist"] as? String ?? "Surround Stream"
            value.album = info["album"] as? String ?? ""
        }
        value.pictures = info["imagePaths"] as? [String] ?? (info["imagePath"] as? String).map { [$0] } ?? []
        value.credit = info["artworkCredit"] as? String ?? ""
    }
    func snapshot()->Snapshot { lock.lock();defer { lock.unlock() };return value }
}
func imageOf(_ bitmap:NSBitmapImageRep) -> NSImage {
    NSImage(cgImage:bitmap.cgImage!,size:NSSize(width:bitmap.pixelsWide,height:bitmap.pixelsHigh))
}
func paint(_ image:NSImage,in rect:NSRect,zoom:Double = 1,pan:Double = 0,alpha:Double = 1) {
    NSGraphicsContext.saveGraphicsState();NSBezierPath(rect:rect).addClip()
    let scale = max(rect.width/image.size.width,rect.height/image.size.height)*zoom
    let w = image.size.width*scale,h = image.size.height*scale
    image.draw(in:NSRect(x:rect.midX-w/2+pan,y:rect.midY-h/2-(h-rect.height)*0.12,width:w,height:h),
        from:.zero,operation:.sourceOver,fraction:alpha)
    NSGraphicsContext.restoreGraphicsState()
}
func text(_ value:String,rect:NSRect,size:CGFloat,weight:NSFont.Weight = .regular,
          color:NSColor = .white,tracking:CGFloat = 0) {
    let p = NSMutableParagraphStyle();p.lineBreakMode = .byWordWrapping
    (value as NSString).draw(in:rect,withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:weight),
        .foregroundColor:color,.kern:tracking,.paragraphStyle:p])
}
// Quick arrival, long gentle glide, accelerating departure. Opposing lines.
func lineOffset(_ t:Double,reverse:Bool)->Double {
    let phase = t.truncatingRemainder(dividingBy:32)-(reverse ? 0.18 : 0)
    let start = reverse ? 1320.0 : -800.0
    if phase<0 { return start }
    if phase<1.5 { return start*pow(1-phase/1.5,4) }
    let drift = (reverse ? -1.0 : 1.0)*12
    if phase<27 { return drift*(phase-1.5)/25.5 }
    if phase<28.3 { return drift+(reverse ? -1500.0 : 1500.0)*pow((phase-27)/1.3,3) }
    return reverse ? -1500 : 1500
}
func makeCard(_ image:NSImage,w:Int,h:Int)->NSImage {
    let b = bitmap(w+100,h+100)
    drawInto(b) {
        let rect = NSRect(x:50,y:50,width:w,height:h)
        let path = NSBezierPath(roundedRect:rect,xRadius:12,yRadius:12)
        let shadow = NSShadow();shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 28;shadow.shadowOffset = NSSize(width:0,height:-12);shadow.set()
        NSColor.black.setFill();path.fill();NSShadow().set();path.addClip()
        paint(image,in:rect,zoom:1.04)
        NSColor.white.withAlphaComponent(0.18).setStroke();path.lineWidth = 1;path.stroke()
    }
    return imageOf(b)
}
func card(_ image:NSImage,rect:NSRect,angle:CGFloat,alpha:Double,elapsed:Double) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform();transform.translateX(by:rect.midX,yBy:rect.midY)
    transform.rotate(byDegrees:angle);transform.concat()
    let zoom = 1+0.006*sin(elapsed/47)
    image.draw(in:NSRect(x:-(rect.width+100)*zoom/2,y:-(rect.height+100)*zoom/2,
        width:(rect.width+100)*zoom,height:(rect.height+100)*zoom),from:.zero,operation:.sourceOver,fraction:alpha)
    NSGraphicsContext.restoreGraphicsState()
}
final class Renderer {
    var paths:[String] = [],photos:[NSImage] = []
    var heroCard:NSImage?,secondaryCards:[NSImage] = []
    var lastKey = "",titleLayer:NSImage?,artistLayer:NSImage?,detailLayer:NSImage?
    var compactOffset:CGFloat = 0
    let gpu = CIContext(options:[.cacheIntermediates:false])
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    var oldFrame:CIImage?,lastFrame:NSBitmapImageRep?,transition = -100.0
    var photoTextures:[CIImage] = [],heroTexture:CIImage?,secondaryTextures:[CIImage] = []
    var titleTexture:CIImage?,artistTexture:CIImage?,detailTexture:CIImage?,chromeTexture:CIImage?
    var chromeKey = ""
    func texture(_ image:NSImage)->CIImage {
        var rect = NSRect(origin:.zero,size:image.size)
        return CIImage(cgImage:image.cgImage(forProposedRect:&rect,context:nil,hints:nil)!)
    }
    func opacity(_ image:CIImage,_ alpha:Double)->CIImage {
        if alpha>=1 { return image }
        return image.applyingFilter("CIColorMatrix",parameters:["inputAVector":CIVector(x:0,y:0,z:0,w:alpha)])
    }
    func photo(_ image:CIImage,_ zoom:Double,_ pan:Double)->CIImage {
        let scale = max(Double(width)/image.extent.width,Double(height)/image.extent.height)*zoom
        let w = image.extent.width*scale,h = image.extent.height*scale
        return image.transformed(by:CGAffineTransform(a:scale,b:0,c:0,d:scale,
            tx:(Double(width)-w)/2+pan,ty:(Double(height)-h)/2-(h-Double(height))*0.12))
            .cropped(to:CGRect(x:0,y:0,width:width,height:height))
    }
    func printPhoto(_ image:CIImage,_ x:Double,_ y:Double,_ angle:Double,_ zoom:Double)->CIImage {
        let transform = CGAffineTransform(translationX:x,y:y).rotated(by:angle*Double.pi/180)
            .scaledBy(x:zoom,y:zoom).translatedBy(x:-image.extent.width/2,y:-image.extent.height/2)
        return image.transformed(by:transform)
    }
    lazy var lighting:NSImage = {
        let b = bitmap(width,height)
        drawInto(b) {
            let canvas = NSRect(x:0,y:0,width:width,height:height)
            NSColor(calibratedRed:0.035,green:0.025,blue:0.02,alpha:0.30).setFill();canvas.fill()
            NSGradient(colors:[NSColor.black.withAlphaComponent(0.94),NSColor.black.withAlphaComponent(0.68),
                NSColor.black.withAlphaComponent(0.18)])?.draw(in:canvas,angle:0)
            NSGradient(colors:[NSColor.black.withAlphaComponent(0.78),NSColor.clear,
                NSColor.black.withAlphaComponent(0.20)])?.draw(in:canvas,angle:90)
        }
        return imageOf(b)
    }()
    func prepare(_ s:Snapshot,now:Double) {
        if paths != s.pictures {
            oldFrame = lastFrame.map { CIImage(cgImage:$0.cgImage!) };transition = now;paths = s.pictures
            photos = paths.compactMap { path in
                guard let original = NSImage(contentsOfFile:path) else { return nil }
                let scale = min(1,1400/max(original.size.width,original.size.height))
                let decoded = bitmap(max(1,Int(original.size.width*scale)),max(1,Int(original.size.height*scale)))
                drawInto(decoded) { original.draw(in:NSRect(x:0,y:0,width:decoded.pixelsWide,height:decoded.pixelsHigh)) }
                return imageOf(decoded)
            }
            heroCard = photos.last.map { makeCard($0,w:370,h:515) }
            secondaryCards = photos.dropLast().map { makeCard($0,w:245,h:354) }
            photoTextures = photos.map { texture($0) }
            heroTexture = heroCard.map { texture($0) }
            secondaryTextures = secondaryCards.map { texture($0) }
        }
        if lastKey != s.key || titleLayer == nil {
            lastKey = s.key
            let title = bitmap(width,height),artist = bitmap(width,height),details = bitmap(width,height)
            drawInto(title) {
                var size:CGFloat = 78
                let paragraph = NSMutableParagraphStyle();paragraph.lineBreakMode = .byWordWrapping
                while size>42 {
                    let box = (s.title as NSString).boundingRect(with:NSSize(width:650,height:1000),
                        options:[.usesLineFragmentOrigin,.usesFontLeading],
                        attributes:[.font:NSFont.systemFont(ofSize:size,weight:.semibold),.paragraphStyle:paragraph])
                    if box.height<195 { break };size-=2
                }
                let measured = (s.title as NSString).boundingRect(with:NSSize(width:650,height:1000),
                    options:[.usesLineFragmentOrigin,.usesFontLeading],
                    attributes:[.font:NSFont.systemFont(ofSize:size,weight:.semibold),.kern:-2,.paragraphStyle:paragraph])
                compactOffset = max(0,195-ceil(measured.height))
                text(s.title,rect:NSRect(x:76,y:322,width:650,height:202),size:size,weight:.semibold,tracking:-2)
            }
            drawInto(artist) {
                text(s.artist,rect:NSRect(x:79,y:269+compactOffset,width:625,height:47),size:31,weight:.light,
                    color:.white.withAlphaComponent(0.90),tracking:0.3)
            }
            drawInto(details) {
                text(s.album,rect:NSRect(x:80,y:227+compactOffset,width:610,height:29),size:17,
                    color:.white.withAlphaComponent(0.48),tracking:0.3)
            }
            titleLayer = imageOf(title);artistLayer = imageOf(artist);detailLayer = imageOf(details)
            titleTexture = texture(titleLayer!);artistTexture = texture(artistLayer!);detailTexture = texture(detailLayer!)
        }
    }
    func frame(_ s:Snapshot,elapsed:Double,now:Double)->NSBitmapImageRep {
        prepare(s,now:now)
        let canvas = CGRect(x:0,y:0,width:width,height:height)
        var image = CIImage(color:CIColor(red:0.025,green:0.035,blue:0.055)).cropped(to:canvas)
        if !photoTextures.isEmpty {
            let cycle = elapsed/22
            let index = Int(cycle)%photoTextures.count,next = (index+1)%photoTextures.count
            let blend = max(0,min(1,(cycle-floor(cycle)-0.84)/0.16))
            image = photo(photoTextures[index],1.07+0.018*sin(elapsed/95),12*sin(elapsed/61))
            if blend>0 {
                image = opacity(photo(photoTextures[next],1.07,-10*sin(elapsed/71)),blend).composited(over:image)
            }
        }
        image = texture(lighting).composited(over:image)
        if let hero = heroTexture {
            let drift = 8*sin(elapsed/23)
            if !secondaryTextures.isEmpty {
                let secondary = secondaryTextures[(Int(elapsed/44)+1)%secondaryTextures.count]
                image = opacity(printPhoto(secondary,1177.5+6*sin(elapsed/31),372+drift,
                    7+0.5*sin(elapsed/47),1+0.006*sin((elapsed+20)/47)),0.70).composited(over:image)
            }
            image = printPhoto(hero,993+6*sin(elapsed/37),352.5+drift,
                -3+0.5*sin(elapsed/43),1+0.006*sin(elapsed/47)).composited(over:image)
        }
        let nextChromeKey = s.key+s.credit
        if chromeTexture == nil || chromeKey != nextChromeKey {
            chromeKey = nextChromeKey
            let b = bitmap(width,height)
            drawInto(b) {
                let amber = NSColor(calibratedRed:0.95,green:0.72,blue:0.44,alpha:1)
                amber.setFill();NSBezierPath(ovalIn:NSRect(x:80,y:557,width:5,height:5)).fill()
                text("N O W   P L A Y I N G",rect:NSRect(x:99,y:548,width:420,height:25),size:12,
                    weight:.medium,color:amber.withAlphaComponent(0.95))
                amber.withAlphaComponent(0.65).setFill();NSRect(x:80,y:205+compactOffset,width:44,height:1).fill()
                text("S U R R O U N D   S T R E A M",rect:NSRect(x:80,y:47,width:500,height:22),size:10,
                    weight:.medium,color:.white.withAlphaComponent(0.37))
                text(s.credit,rect:NSRect(x:912,y:32,width:340,height:19),size:10,
                    color:.white.withAlphaComponent(0.32))
            }
            chromeTexture = CIImage(cgImage:b.cgImage!)
        }
        image = chromeTexture!.composited(over:image)
        if let layer = titleTexture {
            image = layer.transformed(by:CGAffineTransform(translationX:lineOffset(elapsed,reverse:false),y:0)).composited(over:image)
        }
        if let layer = artistTexture {
            image = layer.transformed(by:CGAffineTransform(translationX:lineOffset(elapsed,reverse:true),y:0)).composited(over:image)
        }
        if let layer = detailTexture {
            image = opacity(layer,min(1,max(0,(elapsed-1)/1.5))).composited(over:image)
        }
        if let previous = oldFrame,now-transition<1.15 {
            image = opacity(previous,1-(now-transition)/1.15).composited(over:image)
        } else { oldFrame = nil }
        let frame = bitmap(width,height)
        gpu.render(image,toBitmap:frame.bitmapData!,rowBytes:frame.bytesPerRow,bounds:canvas,
            format:.RGBA8,colorSpace:colorSpace)
        lastFrame = frame
        return frame
    }
}
func render(folder:URL) {
    try? fm.createDirectory(at:folder,withIntermediateDirectories:true)
    let scene = Scene(),renderer = Renderer()
    let initial = renderer.frame(scene.snapshot(),elapsed:3,now:ProcessInfo.processInfo.systemUptime)
    save(initial,folder.appendingPathComponent("background.png"));save(initial,folder.appendingPathComponent("text.png"))
    Thread.detachNewThread {
        while let line = readLine() {
            if let data = line.data(using:.utf8),let value = try? JSONSerialization.jsonObject(with:data) as? [String:Any] {
                scene.update(value)
            }
        }
        exit(0)
    }
    while true {
        autoreleasepool {
            let now = ProcessInfo.processInfo.systemUptime,s = scene.snapshot()
            let frame = renderer.frame(s,elapsed:now-s.updated,now:now)
            if let bytes = frame.bitmapData { FileHandle.standardOutput.write(Data(bytes:bytes,count:frame.bytesPerRow*height)) }
        }
        // The bounded pipe is paced by the encoder's audio clock. No second clock.
    }
}
if CommandLine.arguments.contains("--now-playing") { watchMusic() }
else if CommandLine.arguments.count>=3 && CommandLine.arguments[1]=="--render" {
    render(folder:URL(fileURLWithPath:CommandLine.arguments[2]))
} else if CommandLine.arguments.count>=4 && CommandLine.arguments[1]=="--snapshot" {
    let data = try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))
    let info = try JSONSerialization.jsonObject(with:data) as! [String:Any]
    let scene = Scene();scene.update(info)
    let elapsed = CommandLine.arguments.count>4 ? Double(CommandLine.arguments[4]) ?? 4 : 4
    let renderer = Renderer();let now = ProcessInfo.processInfo.systemUptime
    _ = renderer.frame(scene.snapshot(),elapsed:elapsed,now:now-2)
    save(renderer.frame(scene.snapshot(),elapsed:elapsed,now:now),URL(fileURLWithPath:CommandLine.arguments[3]))
} else { fputs("Usage: TileRenderer --now-playing [--once] | --render folder | --snapshot scene.json output.png [seconds]\n",stderr);exit(1) }
