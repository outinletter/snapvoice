import SwiftUI

@main
struct SnapVoiceApp: App {
    @StateObject private var engine = DictationEngine()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(engine)
                .onOpenURL { _ in engine.startSession() }   // 키보드에서 열면 바로 세션 시작
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var engine: DictationEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("SnapVoice").font(.largeTitle.bold())
                Text("키보드의 마이크 버튼을 누르고 있는 동안 말하면, 손을 뗄 때 바로 입력됩니다.")
                    .foregroundStyle(.secondary)

                Button {
                    engine.running ? engine.stopSession() : engine.startSession()
                } label: {
                    Label(engine.running ? "음성 세션 끄기" : "음성 세션 켜기",
                          systemImage: engine.running ? "stop.circle.fill" : "mic.circle.fill")
                        .frame(maxWidth: .infinity).padding()
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.running ? .red : .blue)

                if !engine.message.isEmpty { Text(engine.message).font(.footnote) }
                if engine.running {
                    Text(engine.recording ? "듣는 중… \(engine.partial)" : "여기를 누른 채 말해서 테스트")
                        .frame(maxWidth: .infinity).padding()
                        .background(engine.recording ? Color.red.opacity(0.3) : Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { _ in if !engine.recording { Bridge.set("ko-KR", Bridge.Key.locale); Bridge.set(String(Date().timeIntervalSince1970), Bridge.Key.startAt); Bridge.post(.start) } }
                            .onEnded { _ in Bridge.post(.stop) })
                }
                if !engine.lastText.isEmpty { Text("마지막 입력: \(engine.lastText)").font(.callout) }

                GroupBox("설정 방법") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. 설정 ▸ 일반 ▸ 키보드 ▸ 키보드 ▸ 새로운 키보드 추가 ▸ SnapVoice")
                        Text("2. SnapVoice ▸ '전체 접근 허용' 켜기")
                        Text("3. 이 앱에서 '음성 세션 켜기' 후 다른 앱으로 이동")
                        Text("4. 글 입력 중 지구본 키로 SnapVoice 키보드 선택 ▸ 마이크 버튼을 누른 채 말하기")
                    }.font(.footnote)
                }
                Text("세션이 켜져 있는 동안 iOS 상단에 마이크 표시가 보입니다. 사용 후 끄면 배터리를 아낄 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding()
        }
    }
}
