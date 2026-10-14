import EMCore
import Foundation

/// Same fixture as EMDetectionTests.testRules() (test targets can't share helpers).
func testRules() throws -> DetectionRules {
    try DetectionRules.decode(Data("""
    {"version":1,"pollIntervalMs":1000,"ignoreBundlePrefixes":["com.apple.CoreSpeech"],
     "apps":[
      {"id":"teams","name":"Microsoft Teams","bundlePrefixes":["com.microsoft.teams2"],"startSignal":"mic","debounceSec":5,"graceSec":15},
      {"id":"zoom","name":"Zoom","bundlePrefixes":["us.zoom"],"startSignal":"mic","debounceSec":5,"graceSec":15},
      {"id":"whatsapp","name":"WhatsApp","bundlePrefixes":["net.whatsapp.WhatsApp"],"startSignal":"mic","debounceSec":8,"graceSec":15}],
     "browsers":[]}
    """.utf8))
}
