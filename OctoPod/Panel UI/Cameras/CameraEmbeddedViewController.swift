import UIKit
import SafariServices  // Used for opening browser in-app

class CameraEmbeddedViewController: UIViewController, OctoPrintSettingsDelegate, UIScrollViewDelegate {

    private static let CAMERA_INFO_GESTURES = "CAMERA_INFO_GESTURES"

    let printerManager: PrinterManager = { return (UIApplication.shared.delegate as! AppDelegate).printerManager! }()
    let octoprintClient: OctoPrintClient = { return (UIApplication.shared.delegate as! AppDelegate).octoprintClient }()

    @IBOutlet weak var imageView: UIImageView!
    
    @IBOutlet weak var printTimeLeftLabel: UILabel!
    @IBOutlet weak var tool0ActualLabel: UILabel!
    @IBOutlet weak var bedActualLabel: UILabel!

    @IBOutlet weak var errorMessageLabel: UILabel!
    @IBOutlet weak var errorURLButton: UIButton!
    
    @IBOutlet weak var tapMessageLabel: UILabel!
    @IBOutlet weak var pinchMessageLabel: UILabel!
    
    var streamingController: MjpegStreamingController?
    
    var cameraURL: String!
    var cameraOrientation: UIImage.Orientation!
    
    var uiPreviousOrientation: UIInterfaceOrientation?
    
    var cameraTappedCallback: (() -> Void)?
    var cameraViewDelegate: CameraViewDelegate?
    var cameraIndex: Int!

    var infoGesturesAvailable: Bool = false // Flag that indicates if page wants to instruct user that gestures are available for full screen and zoom in/out

    override func viewDidLoad() {
        super.viewDidLoad()

        streamingController = MjpegStreamingController(imageView: imageView)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Start listening to events when app comes back from background
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        // Listen when app went to background so we can stop any ongoing HTTP request
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)

        let defaults = UserDefaults.standard
        if defaults.bool(forKey: CameraEmbeddedViewController.CAMERA_INFO_GESTURES) {
            // User already used gestures so hide information labels
            tapMessageLabel.isHidden = true
            pinchMessageLabel.isHidden = true
        } else {
            // User did not use gestures so parent window decides if messages should be displayed
            tapMessageLabel.isHidden = !infoGesturesAvailable
            pinchMessageLabel.isHidden = !infoGesturesAvailable
        }

        // Add a gesture recognizer to camera view so we can handle taps
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleCameraTap))
        imageView.isUserInteractionEnabled = true
        imageView.addGestureRecognizer(tapGesture)

        renderPrinter()
        
        // Listen to changes to OctoPrint Settings in case the camera orientation has changed
        octoprintClient.octoPrintSettingsDelegates.append(self)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Stop listening to events when app comes back from background
        NotificationCenter.default.removeObserver(self)

        // Stop listening to changes to OctoPrint Settings
        octoprintClient.remove(octoPrintSettingsDelegate: self)

        stopRenderingPrinter()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Hide display printer status (so when it comes back there is no old info)
        displayPrintStatus(enabled: false)
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    func stopRenderingPrinter() {
        streamingController?.stop()
    }
    
    func displayPrintStatus(enabled: Bool) {
        DispatchQueue.main.async {
            self.printTimeLeftLabel.isHidden = !enabled
            self.tool0ActualLabel.isHidden = !enabled
            self.bedActualLabel.isHidden = !enabled
            if enabled {
                // Reset values in case they are old
                self.printTimeLeftLabel.text = " "
                self.tool0ActualLabel.text = " "
                self.bedActualLabel.text = " "
            }
        }
    }
    
    // MARK: - Notifications

    func printerSelectedChanged() {
        renderPrinter()
    }
    
    func cameraSelectedChanged() {
        renderPrinter()
    }
    
    func currentStateUpdated(event: CurrentStateEvent) {
        DispatchQueue.main.async {
            if let seconds = event.progressPrintTimeLeft {
                self.printTimeLeftLabel.text = UIUtils.secondsToTimeLeft(seconds: seconds, ifZero: " ")
            } else if event.progressPrintTime != nil {
                self.printTimeLeftLabel.text = NSLocalizedString("Still stabilizing", comment: "Print time is being calculated")
            }

            if let tool0Actual = event.tool0TempActual {
                self.tool0ActualLabel.text = "\(String(format: "%.1f", tool0Actual))C"
            }
            if let bedActual = event.bedTempActual {
                self.bedActualLabel.text = "\(String(format: "%.1f", bedActual))C"
            }
        }
    }
    
    // MARK: - Button actions

    @IBAction func errorURLClicked(_ sender: Any) {
        let svc = SFSafariViewController(url: URL(string: cameraURL)!)
        UIApplication.shared.keyWindow?.rootViewController?.present(svc, animated: true, completion: nil)
    }
    
    // MARK: - Navigation
    
    @objc func handleCameraTap() {
        // Record that user used this feature
        userUsedGestures()
        
        if let callback = cameraTappedCallback {
            callback()
        }
    }

    // MARK: - OctoPrintSettingsDelegate
    
    func sdSupportChanged(sdSupport: Bool) {
        // Do nothing
    }
    
    func cameraOrientationChanged(newOrientation: UIImage.Orientation) {
        setCameraOrientation(newOrientation: newOrientation)
    }
    
    func camerasChanged(camerasURLs: Array<String>) {
        // Do nothing. Parent view controller will take care of this
    }

    // MARK: - UIScrollViewDelegate
    
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return imageView
    }
    
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        // Record that user used this feature
        userUsedGestures()

        if infoGesturesAvailable {
            // Hide info labels
            tapMessageLabel.isHidden = true
            pinchMessageLabel.isHidden = true
        }
    }
    
    // MARK: - Private functions

    fileprivate func renderPrinter() {
        // Hide error messages
        errorMessageLabel.isHidden = true
        errorURLButton.isHidden = true
        
        if let printer = printerManager.getDefaultPrinter() {
            
            setCameraOrientation(newOrientation: cameraOrientation)

            if let url = URL(string: cameraURL.trimmingCharacters(in: .whitespaces)) {
                // Make sure that url button is clickable (visible when not hidden)
                self.errorURLButton.isUserInteractionEnabled = true
                // User authentication credentials if configured for the printer
                if let username = printer.username, let password = printer.password {
                    // Handle user authentication if webcam is configured this way (I hope people are being careful and doing this)
                    streamingController?.authenticationHandler = { challenge in
                        let credential = URLCredential(user: username, password: password, persistence: .forSession)
                        return (.useCredential, credential)
                    }
                }
                
                streamingController?.authenticationFailedHandler = {
                    DispatchQueue.main.async {
                        self.imageView.image = nil
                        // Display error messages
                        self.errorMessageLabel.text = NSLocalizedString("Authentication failed", comment: "HTTP authentication failed")
                        self.errorMessageLabel.numberOfLines = 1
                        self.errorMessageLabel.isHidden = false
                    }
                }
                
                streamingController?.didFinishWithErrors = { error in
                    DispatchQueue.main.async {
                        self.imageView.image = nil
                        // Display error messages
                        self.errorMessageLabel.text = error.localizedDescription
                        self.errorMessageLabel.numberOfLines = 2
                        self.errorURLButton.setTitle(self.cameraURL, for: .normal)
                        self.errorMessageLabel.isHidden = false
                        self.errorURLButton.isHidden = false
                    }
                }
                
                streamingController?.didFinishWithHTTPErrors = { httpResponse in
                    // We got a 404 or some 5XX error
                    DispatchQueue.main.async {
                        self.imageView.image = nil
                        // Display error messages
                        if httpResponse.statusCode == 503 && !printer.isStreamPathFromSettings() {
                            // If URL to camera was not returned via /api/settings and
                            // we got a 503 to the best guessed URL then show "no camera" error message
                            self.errorMessageLabel.text = NSLocalizedString("No camera", comment: "No camera was found")
                            self.errorMessageLabel.numberOfLines = 1
                            self.errorMessageLabel.isHidden = false
                            self.errorURLButton.isHidden = true
                        } else {
                            self.errorMessageLabel.text = String(format: NSLocalizedString("HTTP Request error", comment: "HTTP Request error info"), httpResponse.statusCode)
                            self.errorMessageLabel.numberOfLines = 1
                            self.errorURLButton.setTitle(self.cameraURL, for: .normal)
                            self.errorMessageLabel.isHidden = false
                            self.errorURLButton.isHidden = false
                        }
                    }
                }

                streamingController?.didRenderImage = { (image: UIImage) in
                    // Notify that we got our first image and we know its ratio
                    self.cameraViewDelegate?.imageAspectRatio(cameraIndex: self.cameraIndex, ratio: image.size.height / image.size.width)
                }

                streamingController?.didFinishLoading = {
                    // Hide error messages since an image will be rendered (so that means that it worked!)
                    self.errorMessageLabel.isHidden = true
                    self.errorURLButton.isHidden = true
                }
                
                // Start rendering the camera
                streamingController?.play(url: url)
            } else {
                // Camera URL was not valid (e.g. url string contains characters that are illegal in a URL, or is an empty string)
                self.errorMessageLabel.text = NSLocalizedString("Invalid camera URL", comment: "URL of camera is invalid")
                self.errorMessageLabel.numberOfLines = 1
                self.errorURLButton.setTitle(self.cameraURL, for: .normal)
                self.errorMessageLabel.isHidden = false
                self.errorURLButton.isHidden = false
                self.errorURLButton.isUserInteractionEnabled = false
            }
        }
    }
    
    fileprivate func setCameraOrientation(newOrientation: UIImage.Orientation) {
        streamingController?.imageOrientation = newOrientation
        if newOrientation == UIImage.Orientation.left || newOrientation == UIImage.Orientation.leftMirrored || newOrientation == UIImage.Orientation.rightMirrored || newOrientation == UIImage.Orientation.right {
            DispatchQueue.main.async {
                self.imageView.contentMode = .scaleAspectFit
            }
        } else {
            DispatchQueue.main.async {
                self.imageView.contentMode = .scaleAspectFit
            }
        }
    }
    
    fileprivate func userUsedGestures() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: CameraEmbeddedViewController.CAMERA_INFO_GESTURES)
    }

    @objc func appWillEnterForeground() {
        // Resume rendering printer
        renderPrinter()
    }
    
    @objc func appDidEnterBackground() {
        streamingController?.stop()
    }
}
