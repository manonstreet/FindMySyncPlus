import Foundation
import Security
import Testing
@testable import FindMySyncPlus

/// `MQTTClient.tlsRefusal`: a refused certificate is named; anything else is left to the retry path.
struct MQTTTLSTests {

    private func sslError(_ status: OSStatus) -> NSError {
        NSError(domain: "kCFStreamErrorDomainSSL", code: Int(status))
    }

    @Test func certificateRefusalsAreNamed() {
        #expect(MQTTClient.tlsRefusal(sslError(errSSLCertExpired))?.contains("expired") == true)
        #expect(MQTTClient.tlsRefusal(sslError(errSSLHostNameMismatch))?.contains("different name") == true)
        #expect(MQTTClient.tlsRefusal(sslError(errSSLXCertChainInvalid))?.contains("may be expired") == true)
        #expect(MQTTClient.tlsRefusal(sslError(errSSLXCertChainInvalid))?.contains("-9807") == true)
        #expect(MQTTClient.tlsRefusal(sslError(errSSLUnknownRootCert))?.contains("trust") == true)
    }

    @Test func otherTLSFailuresAreNotRefusals() {
        #expect(MQTTClient.tlsRefusal(sslError(errSSLClosedAbort)) == nil)
    }

    @Test func nonTLSErrorsAreNotRefusals() {
        #expect(MQTTClient.tlsRefusal(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))) == nil)
    }
}
