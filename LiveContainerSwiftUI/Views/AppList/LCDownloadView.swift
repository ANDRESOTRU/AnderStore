//
//  LCDownloadView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2025/1/22.
//

import SwiftUI

@MainActor
public final class DownloadHelper: ObservableObject {
    @Published var downloadProgress: Float = 0
    @Published var downloadedSize: Int64 = 0
    @Published var totalSize: Int64 = 0
    @Published var isDownloading = false
    @Published var isPaused = false
    @Published var cancelled = false
    @Published var showsDownloadOverlay = true
    private var downloadTask: URLSessionDownloadTask?
    private var session: URLSession?
    private var delegate: DownloadDelegate?
    private var continuation: CheckedContinuation<Void, Error>?
    private var requestID: UUID?

    func download(url: URL, to destination: URL, inline: Bool = false,
                  onProgress: ((Int64, Int64) -> Void)? = nil) async throws {
        guard !isDownloading else { throw URLError(.backgroundSessionInUseByAnotherProcess) }
        let id = UUID()
        requestID = id
        cancelled = false; isPaused = false
        downloadProgress = 0; downloadedSize = 0; totalSize = 0
        showsDownloadOverlay = !inline
        isDownloading = true
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            continuation = c
            let configuration = URLSessionConfiguration.background(withIdentifier: "com.livecontainer.download.\(id.uuidString)")
            let delegate = DownloadDelegate(destination: destination, progressCallback: { bytes, total in
                Task { @MainActor in
                    guard self.requestID == id, !self.isPaused else { return }
                    self.downloadedSize = bytes; self.totalSize = total
                    self.downloadProgress = total > 0 ? min(1, Float(bytes) / Float(total)) : 0
                    onProgress?(bytes, total)
                }
            }, completeCallback: { error in
                Task { @MainActor in self.finish(id: id, error: error) }
            })
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: .main)
            self.delegate = delegate
            self.session = session
            downloadTask = session.downloadTask(with: url)
            downloadTask?.resume()
        }
    }

    private func finish(id: UUID, error: Error?) {
        guard requestID == id else { return }
        // Clear ownership before resuming: completion and cancellation may both arrive.
        requestID = nil
        let pending = continuation
        continuation = nil
        isDownloading = false; isPaused = false
        downloadTask = nil
        delegate = nil
        session?.finishTasksAndInvalidate(); session = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }

    func pause() {
        guard isDownloading, !isPaused else { return }
        isPaused = true
        downloadTask?.suspend()
    }

    func resume() {
        guard isDownloading, isPaused else { return }
        isPaused = false
        downloadTask?.resume()
    }

    func cancel() {
        guard let id = requestID else { return }
        cancelled = true
        delegate?.abandon()
        downloadTask?.cancel()
        finish(id: id, error: URLError(.cancelled))
    }
}

struct DownloadAlert : View {
    @StateObject var helper : DownloadHelper
    var body: some View {
        
        Color.black.opacity(0.2) // Semi-transparent grey background
            .edgesIgnoringSafeArea(.all) // Covers entire screen
        
        VStack {
            Text("lc.download.downloading".loc)
                .font(.headline)
                .padding(.top)
            
            ProgressView(value: helper.downloadProgress, total: 1)
                .padding()
            
            Text("\(formatBytes(helper.downloadedSize)) / \(formatBytes(helper.totalSize))")
                .font(.subheadline)
                .padding(.bottom)
            
            Button(action: cancelDownload) {
                Text("lc.common.cancel".loc)
                    .foregroundColor(.red)
                    .padding(.bottom)
            }
        }
        .frame(width: 300)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
        .shadow(radius: 10)
        .padding()
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB] // Allow KB, MB, and GB
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    func cancelDownload() {
        helper.cancel()
    }
}

public struct DownloadAlertModifier: ViewModifier {
    @ObservedObject var helper : DownloadHelper
    @State var show = false
    
    public func body(content: Content) -> some View {

        ZStack {
            content
            if show {
                DownloadAlert(helper: helper)
                
            }
            
        }
        .onChange(of: helper.isDownloading) { newVal in
            withAnimation(.easeInOut(duration: 0.1)) {
                show = newVal && helper.showsDownloadOverlay
            }
        }
    }
}

/// URLSession calls this delegate on its serial main queue. Move the temporary file before
/// returning from didFinishDownloadingTo; its URL expires when that callback returns.
class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let destination: URL
    let progressCallback: (Int64, Int64) -> Void
    let completeCallback: (Error?) -> Void
    private var finished = false

    init(destination: URL, progressCallback: @escaping (Int64, Int64) -> Void,
         completeCallback: @escaping (Error?) -> Void) {
        self.destination = destination
        self.progressCallback = progressCallback
        self.completeCallback = completeCallback
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard !finished else { return }
        progressCallback(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func abandon() { finished = true }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        completeCallback(error)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard !finished else { return }
        guard let response = downloadTask.response as? HTTPURLResponse else {
            finish(URLError(.badServerResponse)); return
        }
        guard (200...299).contains(response.statusCode) else {
            finish(NSError(domain: "AnderDownloadHTTP", code: response.statusCode,
                           userInfo: [NSLocalizedDescriptionKey: "HTTP \(response.statusCode)"])); return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(nil)
        } catch { finish(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(error) }
    }
}

extension View {
    public func downloadAlert(helper: DownloadHelper) -> some View {
        self.modifier(DownloadAlertModifier(helper: helper))
    }
}
