import Foundation
import WebKit

@MainActor
extension SingletonPlayerWebView {
    /// Cancels any page-side queue injection attempt that has not completed yet.
    func cancelQueueInjection() {
        guard let webView else { return }
        let script = """
        (function() {
            if (typeof window.__kasetCancelQueueInjectionAttempt === 'function') {
                window.__kasetCancelQueueInjectionAttempt();
            }
            window.__targetVideoIdToInject = null;
            window.__kasetQueueInjectionClickActive = null;
            window.__kasetQueueInjectionAttemptId = null;
            return 'cancelled';
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Injects a song into YouTube Music's "Up Next" queue by intercepting JSON.stringify
    /// and simulating clicks on the player bar menu. This allows YouTube Music to seamlessly
    /// transition to the target song natively, achieving gapless playback.
    /// - Returns: `true` if the injection script was started. The actual success/failure result
    ///   is reported asynchronously through the singleton player bridge.
    @discardableResult
    // swiftlint:disable:next function_body_length
    func injectNextSong(videoId: String) -> Bool {
        guard let webView = self.webView else { return false }

        let videoIdLiteral = Self.javaScriptStringLiteral(videoId)

        // This script:
        // 1. Installs a one-time `JSON.stringify` wrapper.
        // 2. Opens the current player bar menu and positively identifies "Play next".
        // 3. Arms the payload swapper only for the click turn of that menu item so unrelated
        //    YouTube Music payloads cannot consume the target and falsely confirm injection.
        // 4. Reports success only when that click-scoped payload is swapped.
        // 5. Dismisses/disarms on timeout or failure so stale targets cannot affect later requests.
        let injectionScript = """
        (function(targetVideoId) {
            const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.singletonPlayer;
            const injectionAttemptId = String(Date.now()) + '-' + String(Math.random());
            let timeoutId = null;
            let observer = null;
            let didReport = false;

            function cancelAttempt() {
                didReport = true;
                if (timeoutId) {
                    clearTimeout(timeoutId);
                    timeoutId = null;
                }
                if (observer) {
                    observer.disconnect();
                    observer = null;
                }
                if (window.__kasetQueueInjectionAttemptId === injectionAttemptId) {
                    window.__targetVideoIdToInject = null;
                    window.__kasetQueueInjectionClickActive = null;
                    window.__kasetQueueInjectionAttemptId = null;
                    window.__kasetQueueInjectionReport = null;
                    window.__kasetCancelQueueInjectionAttempt = null;
                }
            }

            window.__kasetCancelQueueInjectionAttempt = cancelAttempt;

            function report(success, reason, reportedVideoId) {
                if (didReport) return;
                didReport = true;
                if (timeoutId) {
                    clearTimeout(timeoutId);
                    timeoutId = null;
                }
                if (window.__kasetQueueInjectionAttemptId === injectionAttemptId) {
                    window.__kasetQueueInjectionAttemptId = null;
                }
                if (window.__kasetQueueInjectionClickActive === injectionAttemptId) {
                    window.__kasetQueueInjectionClickActive = null;
                }
                if (window.__kasetCancelQueueInjectionAttempt === cancelAttempt) {
                    window.__kasetCancelQueueInjectionAttempt = null;
                }
                try {
                    if (bridge) {
                        bridge.postMessage({
                            type: 'QUEUE_INJECTION_RESULT',
                            videoId: reportedVideoId || targetVideoId,
                            success: !!success,
                            reason: reason || ''
                        });
                    }
                } catch (_) {}
            }

            if (!window.__stringifyIntercepted) {
                const originalStringify = JSON.stringify;
                JSON.stringify = function(value, replacer, space) {
                    const shouldSwap = value
                        && typeof value === 'object'
                        && value.videoIds
                        && Array.isArray(value.videoIds)
                        && window.__targetVideoIdToInject
                        && window.__kasetQueueInjectionClickActive === window.__kasetQueueInjectionAttemptId;

                    if (shouldSwap) {
                        const injectedVideoId = window.__targetVideoIdToInject;
                        console.log('[INJECTOR] Swapping ' + value.videoIds[0] + ' -> ' + injectedVideoId);
                        value.videoIds = [injectedVideoId];
                        window.__targetVideoIdToInject = null;
                        window.__kasetQueueInjectionClickActive = null;
                        if (typeof window.__kasetQueueInjectionReport === 'function') {
                            window.__kasetQueueInjectionReport(true, 'swapped', injectedVideoId);
                        }
                    }

                    return originalStringify(value, replacer, space);
                };
                window.__stringifyIntercepted = true;
            }

            window.__kasetQueueInjectionAttemptId = injectionAttemptId;
            window.__kasetQueueInjectionReport = report;

            function clearActiveTarget() {
                if (window.__kasetQueueInjectionAttemptId === injectionAttemptId) {
                    window.__targetVideoIdToInject = null;
                }
                if (window.__kasetQueueInjectionClickActive === injectionAttemptId) {
                    window.__kasetQueueInjectionClickActive = null;
                }
                if (window.__kasetCancelQueueInjectionAttempt === cancelAttempt) {
                    window.__kasetCancelQueueInjectionAttempt = null;
                }
            }

            function fireQueueClick(menuItems) {
                if (window.__kasetQueueInjectionAttemptId !== injectionAttemptId) return false;
                const playNextPathData = "M6 2.86V5H3a1 1 0 00-1 1v12a1 1 0 102 0V7h2v2.137a.5.5 0 00.748.434L13 5.998 6.748 2.426A.5.5 0 006 2.86ZM21 5h-5a1 1 0 100 2h5a1 1 0 100-2Zm0 6H9a1 1 0 000 2h12a1 1 0 000-2Zm0 6H9a1 1 0 000 2h12a1 1 0 000-2Z";
                let targetBtn = null;
                const iconPaths = document.querySelectorAll('path[d="' + playNextPathData + '"]');
                if (iconPaths.length > 0) {
                    targetBtn = iconPaths[0].closest('ytmusic-menu-service-item-renderer');
                }
                if (!targetBtn) {
                    targetBtn = Array.from(menuItems).find(el => {
                        const text = (el.textContent || '').toLowerCase();
                        const ariaLabel = (el.getAttribute('aria-label') || '').toLowerCase();
                        return text.includes('next') || ariaLabel.includes('next');
                    });
                }
                if (!targetBtn) {
                    clearActiveTarget();
                    report(false, 'play-next-item-not-found');
                    return false;
                }

                window.__targetVideoIdToInject = targetVideoId;
                window.__kasetQueueInjectionClickActive = injectionAttemptId;
                targetBtn.click();

                // The player-bar menu command serializes synchronously from the click. If the
                // target was not consumed by then, fail closed instead of leaving a target armed
                // for unrelated YouTube Music requests.
                setTimeout(() => {
                    if (didReport) return;
                    if (window.__kasetQueueInjectionClickActive === injectionAttemptId) {
                        clearActiveTarget();
                        report(false, 'play-next-payload-not-observed');
                    }
                }, 0);
                return true;
            }

            const playerBarMenuBtn = document.querySelector('.middle-controls-buttons.ytmusic-player-bar ytmusic-menu-renderer button');
            if (playerBarMenuBtn) {
                observer = new MutationObserver((mutations, obs) => {
                    if (window.__kasetQueueInjectionAttemptId !== injectionAttemptId) {
                        obs.disconnect();
                        return;
                    }
                    const newMenuItems = document.querySelectorAll('ytmusic-menu-popup-renderer ytmusic-menu-service-item-renderer');
                    if (newMenuItems.length > 0) {
                        obs.disconnect();
                        observer = null;
                        fireQueueClick(newMenuItems);
                        document.body.click();
                    }
                });
                observer.observe(document.body, { childList: true, subtree: true });
                playerBarMenuBtn.click();
                timeoutId = setTimeout(() => {
                    if (observer) {
                        observer.disconnect();
                        observer = null;
                    }
                    if (window.__kasetQueueInjectionAttemptId === injectionAttemptId) {
                        clearActiveTarget();
                        document.body.click();
                        report(false, 'menu-timeout');
                    }
                }, 2000);
            } else {
                console.log('[INJECTOR] Player bar menu not found — song may not be loaded yet');
                clearActiveTarget();
                report(false, 'player-bar-menu-not-found');
            }
        })(\(videoIdLiteral));
        """

        self.logger.info("Injecting video \(videoId) into YouTube Music native queue")
        webView.evaluateJavaScript(injectionScript) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.logger.error("Failed to inject next song: \(error.localizedDescription)")
                self?.coordinator?.playerService.handleWebQueueInjectionResult(
                    videoId: videoId,
                    success: false,
                    reason: error.localizedDescription
                )
            }
        }
        return true
    }
}
