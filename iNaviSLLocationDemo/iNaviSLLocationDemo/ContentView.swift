import SwiftUI
import UIKit
import InaviSLLocation
import CoreMotion
import CoreLocation
import Combine

enum DetailMode: String, CaseIterable {
    case image = "이미지"
    case data = "데이터"
    case section = "구간"
    case lap = "랩"
}

@MainActor
final class LocationStore: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var status: String = "대기 중"
    @Published var isTracking: Bool = false
    @Published var sessions: [String] = []
    @Published var selectedSessionId: Int64? = nil
    @Published var currentSessionId: Int64? = nil
    @Published var routeImage: UIImage? = nil
    @Published var detailMode: DetailMode = .image
    @Published var currentPoint: CurrentPoint? = nil
    @Published var trackingResult: TrackingResult? = nil
    @Published var currentUiData: UIData? = nil
    @Published var resumeCandidate: String? = nil

    private let locationManager = CLLocationManager()
    private let motionActivityManager = CMMotionActivityManager()
    private var pendingResumeId: Int64? = nil
    private var hasPendingStart = false
    private var hasPendingLocationUpdate = false

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "ko_KR")
        return f
    }()

    override init() {
        super.init()
        SamsungLifeService.shared.initialize(context: nil, licenseKey: "YOUR_LICENSE_KEY")
        locationManager.delegate = self
        startObservers()
        fetchSessionIds()
        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            Task { _ = try? await SamsungLifeService.shared.startLocationUpdate(activity: nil) }
        case .notDetermined:
            hasPendingLocationUpdate = true
            locationManager.requestWhenInUseAuthorization()
        default:
            break
        }
    }

    deinit {
        SamsungLifeService.shared.setCurrentPointListener(listener: nil)
        SamsungLifeService.shared.setUiDataListener(listener: nil)
    }

    func fetchSessionIds() {
        Task {
            let ids = (try? await SamsungLifeService.shared.getSessionIds()) ?? []
            await MainActor.run { self.sessions = ids }
        }
    }

    func start() {
        hasPendingStart = true
        pendingResumeId = nil
        requestPermissionsAndStart()
    }

    func resume(sessionId: Int64) {
        hasPendingStart = true
        resumeCandidate = nil
        pendingResumeId = sessionId
        requestPermissionsAndStart()
    }

    func cancelResume() {
        resumeCandidate = nil
    }

    private func requestPermissionsAndStart() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            status = "권한 요청 중..."
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            status = "권한 거부됨 - 설정에서 위치 권한 허용 필요"
        default:
            hasPendingStart = false
            requestMotionThenStart()
        }
    }

    private func requestMotionThenStart() {
        guard CMMotionActivityManager.isActivityAvailable() else {
            Task { await runStart(resumeSessionId: pendingResumeId) }
            return
        }
        if CMMotionActivityManager.authorizationStatus() == .denied {
            status = "권한 거부됨 - 설정에서 동작 권한 허용 필요"
            hasPendingStart = false
            return
        }
        let resumeId = pendingResumeId
        var hasStarted = false
        motionActivityManager.startActivityUpdates(to: .main) { [weak self] _ in
            guard !hasStarted, let self else { return }
            hasStarted = true
            self.motionActivityManager.stopActivityUpdates()
            Task { @MainActor in await self.runStart(resumeSessionId: resumeId) }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                if self.hasPendingLocationUpdate {
                    self.hasPendingLocationUpdate = false
                    Task { _ = try? await SamsungLifeService.shared.startLocationUpdate(activity: nil) }
                }
                if self.hasPendingStart {
                    self.hasPendingStart = false
                    self.requestMotionThenStart()
                }
            case .denied, .restricted:
                if self.hasPendingStart {
                    self.hasPendingStart = false
                    self.status = "권한 거부됨 - 설정에서 위치 권한 허용 필요"
                }
            default:
                break
            }
        }
    }

    func runStart(resumeSessionId: Int64?) async {
        do {
            // 기본 설정 사용 — `SamsungLifeTrackingConfig.companion.DEFAULT`
            // 사용자 정의 예시:
            //   let config = SamsungLifeTrackingConfig(
            //       sectionIntervalMeters: 200.0,  // 구간 m 단위
            //       weightKg: 65.0                 // 칼로리 계산용 체중(kg)
            //   )
            let sessionId: Int64?
            if let sid = resumeSessionId {
                let ok = (try await SamsungLifeService.shared.restartTracking(
                    sessionId: sid,
                    config: SamsungLifeTrackingConfig.companion.DEFAULT
                )).boolValue
                sessionId = ok ? sid : nil
            } else {
                sessionId = (try await SamsungLifeService.shared.startTracking(
                    config: SamsungLifeTrackingConfig.companion.DEFAULT
                ))?.int64Value
            }
            if let sid = sessionId {
                status = resumeSessionId != nil ? "측위 재개" : "측위 중"
                isTracking = true
                currentSessionId = sid
                selectedSessionId = sid
                if resumeSessionId == nil { currentUiData = nil }
                fetchSessionIds()
            } else {
                status = "권한 없음 - 설정에서 위치/동작 권한 허용 필요"
            }
        } catch {
            status = "오류: \(error.localizedDescription)"
        }
    }

    func stop() async {
        do {
            try await SamsungLifeService.shared.stopTracking()
        } catch {
            status = "중지 오류: \(error.localizedDescription)"
        }
        isTracking = false
        currentSessionId = nil
        status = "측위 중지됨"
        fetchSessionIds()
        if let sid = selectedSessionId {
            await loadTrackingResult(sessionId: sid)
        }
    }

    func select(sessionId: Int64) {
        if selectedSessionId == sessionId { return }
        selectedSessionId = sessionId

        routeImage = nil
        trackingResult = nil
        // 종료된 세션이면 결과 로드 (진행중 세션은 live flow 로 표시)
        if sessionId != currentSessionId {
            Task { await loadTrackingResult(sessionId: sessionId) }
        }
        if detailMode == .image {
            Task { await loadRouteImage(sessionId: sessionId) }
        }

        // resume 여부는 loadTrackingResult 완료 후 endTimeMillis 확인 후 결정
    }

    func onDetailModeChanged() {
        guard let sessionId = selectedSessionId else { return }
        if detailMode == .image {
            Task { await loadRouteImage(sessionId: sessionId) }
        } else if sessionId != currentSessionId {
            Task { await loadTrackingResult(sessionId: sessionId) }
        }
    }

    private func loadRouteImage(sessionId: Int64) async {
        do {
            // 기본 설정 사용 — `RouteImageConfig.companion.DEFAULT`
            // 사용자 정의 예시:
            //   let config = RouteImageConfig(
            //       width: 1024,                  // 이미지 가로(px)
            //       height: 1024,                 // 이미지 세로(px)
            //       padding: 60,                  // 가장자리 여백(px)
            //       backgroundColor: 0xFFFFFFFF,  // ARGB
            //       lineColor: 0xFF2196F3,        // 경로선 색상(ARGB)
            //       lineWidth: 6.0,               // 경로선 두께(px)
            //       startMarkerColor: 0xFF4CAF50, // 시작 마커 색상(ARGB)
            //       endMarkerColor: 0xFFF44336,   // 종료 마커 색상(ARGB)
            //       markerRadius: 10.0,           // 마커 반지름(px)
            //       drawMarkers: true             // 시작/종료 마커 표시 여부
            //   )
            let image = try await SamsungLifeService.shared.getSessionRouteImage(
                sessionId: sessionId,
                config: RouteImageConfig.companion.DEFAULT
            )
            self.routeImage = image
        } catch {
            self.routeImage = nil
        }
    }

    private func loadTrackingResult(sessionId: Int64) async {
        do {
            let result = try await SamsungLifeService.shared.getTrackingResult(
                sessionId: sessionId,
                lapDistanceMeters: 400.0
            )
            self.trackingResult = result
            // 미종료 세션(endTimeMillis==0)이고 현재 트래킹 중이 아닐 때만 재개 다이얼로그
            if let r = result, r.endTimeMillis == 0, currentSessionId == nil {
                resumeCandidate = String(sessionId)
            }
        } catch {
            self.trackingResult = nil
        }
    }

    private func startObservers() {
        SamsungLifeService.shared.setCurrentPointListener { [weak self] point in
            guard let self = self else { return }
            Task { @MainActor in
                self.currentPoint = point
            }
        }
        SamsungLifeService.shared.setUiDataListener { [weak self] data in
            guard let self = self else { return }
            Task { @MainActor in
                self.currentUiData = data
            }
        }
    }

}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var store = LocationStore()

    var body: some View {
        VStack(spacing: 0) {
            // 트래킹 컨트롤
            TrackingControlRow(
                status: store.status,
                isTracking: store.isTracking,
                onStart: { store.start() },
                onStop: { Task { await store.stop() } }
            )

            // 세션 목록
            SectionTitle(title: "세션 목록", trailing: "총 \(store.sessions.count)개")

            SessionListView(
                sessions: store.sessions,
                selectedId: store.selectedSessionId,
                onSelect: { store.select(sessionId: $0) }
            )

            // 세션 상세
            SectionTitle(
                title: "세션 상세",
                trailing: store.selectedSessionId.map { "#\($0)" } ?? "선택 없음"
            )

            DetailToolbar(mode: $store.detailMode)
                .onChange(of: store.detailMode) { _ in store.onDetailModeChanged() }

            // 상세 내용
            Group {
                let isLive = store.selectedSessionId != nil && store.selectedSessionId == store.currentSessionId
                switch store.detailMode {
                case .image:
                    ImagePane(image: store.routeImage)
                case .data:
                    DataPane(
                        hasSession: store.selectedSessionId != nil,
                        result: store.trackingResult,
                        isLive: isLive,
                        liveUiData: store.currentUiData
                    )
                case .section:
                    SectionPane(
                        result: store.trackingResult,
                        isLive: isLive,
                        liveUiData: store.currentUiData
                    )
                case .lap:
                    LapPane(result: store.trackingResult)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            CurrentPointPane(
                point: store.currentPoint
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .alert(
            "이어서 진행하시겠습니까?",
            isPresented: Binding(
                get: { store.resumeCandidate != nil },
                set: { if !$0 { store.cancelResume() } }
            ),
            presenting: store.resumeCandidate
        ) { candidate in
            Button("이어하기") {
                store.resume(sessionId: Int64(candidate) ?? 0)
            }
            Button("취소", role: .cancel) { store.cancelResume() }
        } message: { candidate in
            Text("진행 중이던 세션 #\(candidate)이 있습니다.")
        }
    }
}

// MARK: - TrackingControlRow

private struct TrackingControlRow: View {
    let status: String
    let isTracking: Bool
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button("Start", action: onStart)
                .disabled(isTracking)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isTracking ? Color.gray.opacity(0.3) : Color.blue.opacity(0.15))
                .cornerRadius(8)

            Button("Stop", action: onStop)
                .disabled(!isTracking)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(!isTracking ? Color.gray.opacity(0.3) : Color.red.opacity(0.15))
                .cornerRadius(8)
        }

        Text(status)
            .font(.system(size: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }
}

// MARK: - SectionTitle

private struct SectionTitle: View {
    let title: String
    let trailing: String

    var body: some View {
        HStack {
            Text(title)
                .fontWeight(.bold)
            Spacer()
            Text(trailing)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(.top, 12)
    }
}

// MARK: - SessionListView

private struct SessionListView: View {
    let sessions: [String]
    let selectedId: Int64?
    let onSelect: (Int64) -> Void

    var body: some View {
        if sessions.isEmpty {
            Text("(저장된 세션 없음)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sessions, id: \.self) { id in
                        SessionRow(
                            label: id,
                            selected: Int64(id) == selectedId,
                            onTap: { onSelect(Int64(id) ?? 0) }
                        )
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }
}

// MARK: - SessionRow

private struct SessionRow: View {
    let label: String
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(selected ? Color.accentColor : Color.clear)
                .frame(width: 3, height: 16)

            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

// MARK: - DetailToolbar

private struct DetailToolbar: View {
    @Binding var mode: DetailMode

    var body: some View {
        Picker("", selection: $mode) {
            ForEach(DetailMode.allCases, id: \.self) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .padding(.top, 4)
    }
}

// MARK: - ImagePane

private struct ImagePane: View {
    let image: UIImage?

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
        } else {
            Text("(이미지 없음 — 포인트가 2개 이상 필요)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - DataPane

private struct DataPane: View {
    let hasSession: Bool
    let result: TrackingResult?
    let isLive: Bool
    let liveUiData: UIData?

    private var effectivePace: Double {
        isLive ? (liveUiData?.averagePace ?? 0.0) : (result?.averagePaceSecPerKm ?? 0.0)
    }

    private var effectiveMovingPace: Double {
        isLive ? (liveUiData?.averagePaceMove ?? 0.0) : (result?.averageMovingPaceSecPerKm ?? 0.0)
    }

    private var effectiveStats: MovementStats {
        if isLive { return liveUiData?.movement ?? emptyMovementStats }
        guard let r = result else { return emptyMovementStats }
        return MovementStats(
            runningDistanceMeters: r.runningDistanceKm * 1000.0,
            walkingDistanceMeters: r.walkingDistanceKm * 1000.0,
            runningDurationMillis: r.runningTimeMillis,
            walkingDurationMillis: r.walkingTimeMillis,
            idleDurationMillis: r.idleTimeMillis,
            excludedDurationMillis: r.excludedTimeMillis,
            currentStateName: "IDLE"
        )
    }

    private var emptyMovementStats: MovementStats {
        MovementStats(
            runningDistanceMeters: 0,
            walkingDistanceMeters: 0,
            runningDurationMillis: 0,
            walkingDurationMillis: 0,
            idleDurationMillis: 0,
            excludedDurationMillis: 0,
            currentStateName: "IDLE"
        )
    }

    var body: some View {
        if hasSession {
            let stats = effectiveStats
            let distance = isLive ? (liveUiData?.distance ?? 0.0) : ((result?.totalDistanceKm ?? 0.0) * 1000.0)
            let elevGain = isLive ? (liveUiData?.elevationGainMeters ?? 0.0) : (result?.elevationGainMeters ?? 0.0)
            let elevLoss = isLive ? (liveUiData?.elevationLossMeters ?? 0.0) : (result?.elevationLossMeters ?? 0.0)
            let kcal = isLive ? (liveUiData?.kcal ?? 0.0) : (result?.caloriesKcal ?? 0.0)
            let stepCount = isLive ? (liveUiData?.totalSteps ?? 0) : (result?.totalSteps ?? 0)
            let cadenceMin = isLive ? (liveUiData?.cadence.minSpm ?? 0) : (result?.minCadenceSpm ?? 0)
            let cadenceMax = isLive ? (liveUiData?.cadence.maxSpm ?? 0) : (result?.maxCadenceSpm ?? 0)
            let cadenceAvg = isLive ? (liveUiData?.cadence.averageSpm ?? 0) : (result?.averageCadenceSpm ?? 0)
            let debugPace = liveUiData?.averagePaceStr ?? ""
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    StatRow(
                        label: "거리",
                        value: String(format: "%.2fm", distance)
                    )
                    StatRow(
                        label: "페이스",
                        value: (isLive && !debugPace.isEmpty)
                            ? "\(ExtensionKt.formatPace(effectivePace))/km  [\(debugPace)]"
                            : "\(ExtensionKt.formatPace(effectivePace))/km"
                    )
                    StatRow(
                        label: "이동페이스",
                        value: "\(ExtensionKt.formatPace(effectiveMovingPace))/km"
                    )
                    StatRow(
                        label: "칼로리",
                        value: String(format: "%.1f kcal", kcal)
                    )
                    StatRow(
                        label: "걸음수",
                        value: "\(stepCount.formatted()) 걸음"
                    )
                    StatRow(
                        label: "케이던스",
                        value: "최소:\(cadenceMin) 최대:\(cadenceMax) 평균:\(cadenceAvg) spm"
                    )
                    StatRow(
                        label: "상승고도",
                        value: String(format: "%.1fm", elevGain)
                    )
                    StatRow(
                        label: "하강고도",
                        value: String(format: "%.1fm", elevLoss)
                    )
                    StatRow(
                        label: "러닝시간",
                        value: String(
                            format: "%@  (%.1fm)",
                            ExtensionKt.formatDuration(stats.runningDurationMillis),
                            stats.runningDistanceMeters
                        )
                    )
                    StatRow(
                        label: "걷기시간",
                        value: String(
                            format: "%@  (%.1fm)",
                            ExtensionKt.formatDuration(stats.walkingDurationMillis),
                            stats.walkingDistanceMeters
                        )
                    )
                    StatRow(
                        label: "대기시간",
                        value: ExtensionKt.formatDuration(stats.idleDurationMillis)
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("(세션 선택 없음)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 96, alignment: .leading)
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
            Divider()
        }
    }
}

// MARK: - SectionPane

private struct SectionPane: View {
    let result: TrackingResult?
    let isLive: Bool
    let liveUiData: UIData?

    var body: some View {
        if !isLive && result == nil {
            Text("(세션 선택 없음)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let averagePace   = isLive ? (liveUiData?.averagePace ?? 0.0)         : (result?.averagePaceSecPerKm ?? 0.0)
            let bestPace      = isLive ? (liveUiData?.bestPace ?? 0.0)            : (result?.bestPaceSecPerKm ?? 0.0)
            let sections      = isLive ? (liveUiData?.sectionElevations ?? [])    : (result?.sectionElevations ?? [])
            let paces         = isLive ? (liveUiData?.sectionPaces ?? [])         : (result?.sectionPaces ?? [])

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text(String(format: "평균: %@/km  최고: %@/km",
                                ExtensionKt.formatPace(averagePace),
                                ExtensionKt.formatPace(bestPace)))
                        .font(.system(size: 12, design: .monospaced))
                        .fontWeight(.bold)

                    Divider().padding(.vertical, 6)

                    if sections.isEmpty {
                        Text("(구간 데이터 없음)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(sections, id: \.sectionIndex) { section in
                            let paceIdx = Int(section.sectionIndex)
                            let pace: SectionPace? = (paceIdx >= 0 && paceIdx < paces.count) ? paces[paceIdx] : nil
                            VStack(alignment: .leading, spacing: 1) {
                                Text(String(format: "구간 %d", section.sectionIndex + 1))
                                    .font(.system(size: 11, design: .monospaced))
                                    .fontWeight(.semibold)
                                Text(String(format: "  상승=%.1fm  하강=%.1fm  순변화=%.1fm",
                                            section.elevationGainMeters,
                                            section.elevationLossMeters,
                                            section.netElevationChangeMeters))
                                    .font(.system(size: 11, design: .monospaced))
                                if let pace = pace {
                                    Text(String(format: "  페이스=%@/km  첫구간대비=%@/km",
                                                ExtensionKt.formatPace(pace.paceSecPerKm),
                                                ExtensionKt.formatPaceDiff(pace.diffFromFirstSecPerKm)))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(pace.diffFromFirstSecPerKm <= 0 ? .blue : .red)
                                }
                            }
                            .padding(.vertical, 2)
                            Divider()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - LapPane

private struct LapPane: View {
    let result: TrackingResult?

    var body: some View {
        if let result = result {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text(String(format: "랩 거리: %.2fkm  총 %d랩",
                                result.lapDistanceKm, Int(result.lapCount)))
                        .font(.system(size: 12, design: .monospaced))
                        .fontWeight(.bold)

                    Divider().padding(.vertical, 6)

                    if result.laps.isEmpty {
                        Text("(랩 데이터 없음)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(result.laps, id: \.lapNumber) { lap in
                            let isPartial = lap.distanceKm < result.lapDistanceKm - 0.001
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(Int(lap.lapNumber))랩" + (isPartial ? "  (부분)" : ""))
                                    .font(.system(size: 11, design: .monospaced))
                                    .fontWeight(.semibold)
                                    .foregroundColor(isPartial ? .gray : .primary)
                                Text(String(format: "  거리=%.2fkm  시간=%@  페이스=%@/km",
                                            lap.distanceKm,
                                            ExtensionKt.formatDuration(lap.timeMillis),
                                            ExtensionKt.formatPace(lap.paceSecPerKm)))
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            .padding(.vertical, 2)
                            Divider()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("(세션 선택 없음 — 종료된 세션만 조회 가능)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}


// MARK: - CurrentPointPane

private struct CurrentPointPane: View {
    let point: CurrentPoint?

    var body: some View {
        HStack {
            Text("현재 포인트")
                .fontWeight(.bold)
            Spacer()
            Text(point != nil ? "실시간" : "대기")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(.top, 12)

        VStack(alignment: .leading, spacing: 2) {
            if let p = point {
                Text(String(format: "lat=%.6f  lon=%.6f", p.latitude, p.longitude))
                Text(String(format: "speed=%.1f m/s",
                            Float(truncating: p.speed ?? 0)))
            } else {
                Text("(측위 중이 아님)")
                    .foregroundColor(.secondary)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
