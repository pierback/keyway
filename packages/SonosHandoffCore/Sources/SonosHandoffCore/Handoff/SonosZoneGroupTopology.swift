import Foundation

struct SonosZoneGroupTopology {
    private let soapClient: SonosSOAPClient

    init(soapClient: SonosSOAPClient) {
        self.soapClient = soapClient
    }

    func groupState(host: String, visibleSpeakers: [SonosSpeaker]) async throws -> SonosGroupState {
        let response = try await soapClient.call(
            host: host,
            service: "ZoneGroupTopology",
            action: "GetZoneGroupState",
            path: "/ZoneGroupTopology/Control",
            body: """
            <u:GetZoneGroupState xmlns:u="urn:schemas-upnp-org:service:ZoneGroupTopology:1"></u:GetZoneGroupState>
            """
        )

        let stateXML = try stateXML(from: response)
        return try SonosZoneGroupStateParser.parse(stateXML, visibleSpeakers: visibleSpeakers)
    }

    private func stateXML(from response: String) throws -> String {
        if let rawState = SonosRuntimeSupport.firstMatch(
            #"<CurrentZoneGroupState(?:\s[^>]*)?>(.*?)</CurrentZoneGroupState>"#,
            in: response
        ) {
            return SonosRuntimeSupport.xmlUnescape(rawState)
        }

        let unescapedResponse = SonosRuntimeSupport.xmlUnescape(response)
        if let zoneGroups = SonosRuntimeSupport.firstMatch(
            #"(<ZoneGroups(?:\s[^>]*)?>.*?</ZoneGroups>)"#,
            in: unescapedResponse
        ) {
            return zoneGroups
        }

        throw ConnectHandoffError(.unsupported, "Could not read Sonos group topology.")
    }
}

enum SonosZoneGroupStateParser {
    static func parse(_ xml: String, visibleSpeakers: [SonosSpeaker]) throws -> SonosGroupState {
        let delegate = ZoneGroupStateParserDelegate(visibleSpeakers: visibleSpeakers)
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        guard parser.parse() else {
            throw ConnectHandoffError(.unsupported, "Could not parse Sonos group topology.")
        }

        return delegate.groupState()
    }
}

private final class ZoneGroupStateParserDelegate: NSObject, XMLParserDelegate {
    private struct PendingGroup {
        let id: String
        let coordinatorID: String
        var members: [SonosSpeaker]
    }

    private let visibleSpeakerByID: [String: SonosSpeaker]
    private let hasVisibilitySnapshot: Bool
    private var groups: [PendingGroup] = []
    private var currentGroup: PendingGroup?

    init(visibleSpeakers: [SonosSpeaker]) {
        self.visibleSpeakerByID = Dictionary(uniqueKeysWithValues: visibleSpeakers.map { ($0.id, $0) })
        self.hasVisibilitySnapshot = !visibleSpeakers.isEmpty
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "ZoneGroup":
            guard let coordinatorID = attributeDict["Coordinator"]?.nilIfEmpty else {
                currentGroup = nil
                return
            }
            currentGroup = PendingGroup(
                id: attributeDict["ID"]?.nilIfEmpty ?? coordinatorID,
                coordinatorID: coordinatorID,
                members: []
            )
        case "ZoneGroupMember":
            guard let member = speaker(from: attributeDict),
                  attributeDict["Invisible"] != "1"
            else {
                return
            }
            currentGroup?.members.append(member)
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName == "ZoneGroup",
              let group = currentGroup
        else {
            return
        }

        if groupIsVisible(group) {
            groups.append(group)
        }
        currentGroup = nil
    }

    func groupState() -> SonosGroupState {
        SonosGroupState(
            groups: groups
                .map { group in
                    SonosSpeakerGroup(
                        id: group.id,
                        coordinatorID: group.coordinatorID,
                        members: normalizedMembers(group.members, coordinatorID: group.coordinatorID)
                    )
                }
                .sorted {
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
        )
    }

    private func speaker(from attributes: [String: String]) -> SonosSpeaker? {
        guard let id = attributes["UUID"]?.nilIfEmpty,
              let roomName = attributes["ZoneName"]?.nilIfEmpty
        else {
            return nil
        }

        if let visibleSpeaker = visibleSpeakerByID[id] {
            return visibleSpeaker
        }

        guard !hasVisibilitySnapshot else {
            return nil
        }

        guard let host = attributes["Location"].flatMap(Self.host(fromLocation:)) else {
            return nil
        }
        return SonosSpeaker(id: id, roomName: roomName, host: host)
    }

    private func groupIsVisible(_ group: PendingGroup) -> Bool {
        guard !group.members.isEmpty else {
            return false
        }

        guard hasVisibilitySnapshot else {
            return true
        }

        return group.members.contains { $0.id == group.coordinatorID }
    }

    private static func host(fromLocation location: String) -> String? {
        URL(string: location)?.host?.nilIfEmpty
    }

    private func normalizedMembers(_ members: [SonosSpeaker], coordinatorID: String) -> [SonosSpeaker] {
        members
            .uniqued { $0.id }
            .sorted { left, right in
                if left.id == coordinatorID {
                    return true
                }
                if right.id == coordinatorID {
                    return false
                }
                return left.roomName.localizedCaseInsensitiveCompare(right.roomName) == .orderedAscending
            }
    }
}
