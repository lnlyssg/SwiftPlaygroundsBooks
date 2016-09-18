//
//  SceneController.swift
//
//  Copyright (c) 2016 Apple Inc. All Rights Reserved.
//

import SceneKit
import UIKit

final class SceneController: UIViewController {
    // MARK: Properties
    
    let scene: Scene
    
    let posterImageView = UIImageView()
    
    let scnView = SCNView()
    
    let loadingQueue = OperationQueue()
    
    /// Marks if loading is currently in progress. 
    /// Set after the first call to `startRunningSceneIfReady()`.
    var isLoading = false
    
    var cameraController: CameraController?
    
    lazy var characterPicker: CharacterPickerController = CharacterPickerController(view: self.scnView)
    
    /// A view which displays the current goal count.
    let goalCounter = GoalCounter()

    /// An overlay which shows the underlying coordinate system when touching the grid.
    var overlay: GridOverlay?
    
    /// End-State
    
    /// Marks if the current run of the world ended in a passing state.
    var isPassingRun = false
    
    var isDisplayingEndState = false
    
    let speedButton = UIButton()

    /// The index representing the currently selected speed.
    var speedIndex = 0 {
        didSet {
            let totalPossibleSpeeds = WorldConfiguration.Actor.possibleSpeeds.count
            
            speedIndex = max(0, speedIndex) % totalPossibleSpeeds
            
            setCommandSpeedForSpeedIndex()
            
            // Save the speed index.
            Persisted.speedIndex = speedIndex
        }
    }
    
    // MARK: Initialization
    
    init(scene: Scene) {
        self.scene = scene
        
        super.init(nibName: nil, bundle: nil)
        
        // Register as the delegate to update with state changes. See SceneController+StateChanges.swift
        scene.delegate = self
    }
    
    required init(coder aDecoder: NSCoder) {
        fatalError("This method has not been implemented.")
    }
    
    /// Loads any new geometry and animation for the current `commandQueue`.
    /// Specific a `queue` with which to load geometry on.
    /// If immediately displaying the item, `.main` is recommended.
    func beginLoading(queue: OperationQueue = .main) {
        // Loading
        loadingQueue.qualityOfService = .userInitiated
        loadingQueue.maxConcurrentOperationCount = 2
        
        beginLoadingGeometry()
        beginLoadingAnimations()
    }
    
    // MARK: View Controller Life Cycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        addViews()
        
        loadingQueue.addOperation { [weak self] in
            /// Load the `SCNScene`.
            guard let scene = self?.scene.scnScene else { return }
            
            self?.scnView.scene = scene
            self?.sceneDidLoad(scene)
        }
        
        /*
         Register as an `SCNSceneRendererDelegate` to receive updates.
         (Used to determine when the LiveView poster should be removed).
         */
        scnView.delegate = self
        
        // Register for accessibility notifications to update view if 
        // VoiceOver status changes while level is running.
        registerForAccessibilityNotifications()
        
        // Register for tap a tap gesture to display the character picker, or an overlay marker.
        registerForTapGesture()
        
        scnView.isPlaying = true
        scnView.contentMode = .center
        configureViewForDevice()
        
        // Run through the `Display` options.
        if Display.coordinateMarkers {
            // Adds an overlay to mark the underlying coordinate system.
            overlay = GridOverlay(world: scene.gridWorld)
        }
        
        if Display.goalCounter {
            // Add a view to display the current goal collection/ toggle count.
            addGoalCounter()
        }
        
        // Controls
        addControlButtons()
        showControls(false, animated: false)

        speedIndex = Persisted.speedIndex
        
        // Register as the `commandQueue` delegate to update counters when commands are run. 
        scene.commandQueue.delegate = self
        scene.commandQueue.reportsAddedCommands = false
        
        #if DEBUG
        scnView.showsStatistics = true
        
        // For debug purposes set the LiveViewProcess pid.
        liveViewProcessId = getpid()
        #endif
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        // Reconfigure the view for the current VoiceOver status whenever
        // the layout changes.
        setVoiceOverForCurrentStatus(forceLayout: true)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        unregisterForAccessibilityNotifications()
        loadingQueue.cancelAllOperations()
    }
    
    /// Adds the `scnView` and `posterImageView`.
    private func addViews() {
        scnView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scnView)
        scnView.frame = view.bounds
        
        posterImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(posterImageView)
        posterImageView.frame = view.bounds
        
        posterImageView.image = UIImage(named: "LiveViewPoster.png")
        posterImageView.contentMode = .center
    }
    
    /// Called after the scene has been manually assigned to the SCNView.
    private func sceneDidLoad(_: SCNScene) {
        // Now that the scene has been loaded, trigger a
        // verification pass.
        scene.state = .built
        
        // Set controller after scene has been initialized on `scnView`.
        cameraController = CameraController(view: scnView)
        
        // Adjust the `effectsLevel` based on the hardware class.
        #if (arch(i386) || arch(x86_64)) && os(iOS)
            // Setup for the simulator
            scene.effectsLevel = .med
        #else
            if let defaultDevice = scnView.device,
                defaultDevice.supportsFeatureSet(.iOS_GPUFamily2_v2) {
                scene.effectsLevel = .high
            }
            else {
                scene.effectsLevel = .med
            }
        #endif
    }
    
    /// Sets the world and actor `commandSpeed` based on the current `speedIndex`.
    func setCommandSpeedForSpeedIndex() {
        GridWorld.commandSpeed = WorldConfiguration.Scene.possibleSpeeds[speedIndex]
        Actor.commandSpeed = WorldConfiguration.Actor.possibleSpeeds[speedIndex]
        
        setSpeedImage(for: speedButton)
    }
    
    func showControls(_ show: Bool, animated: Bool = true) {
        let newAlpha: CGFloat = show ? 1 : 0
        let controls = view.subviews.filter {
            return $0 is WorldControl
        }
        
        let duration = animated ? WorldConfiguration.controlsFadeDuration : 0
        UIView.animate(withDuration: duration, delay: 0, options: .curveEaseIn, animations: {
            for view in controls {
                view.alpha = newAlpha
            }
        }, completion: nil)
    }
    
    // MARK: Start
    
    func startPlayback() {
        // Make sure the scene is not already running.
        guard scene.state != .run else { return }
        
        // Increment the execution count.
        currentPageRunCount += 1
        
        // Prepare the scene for playback.
        if case .built = scene.state {
            scene.state = .ready
        }

        // Load any new animations and geometry that may be associated with this run.
        beginLoading(queue: loadingQueue)
        
        startRunningSceneWhenReady()
        
        // Reset end state.
        isDisplayingEndState = false
    }
    
    private func startRunningSceneWhenReady() {
        // Ensure that the scene is not already running or in the process of loading.
        guard scene.state != .run && !isLoading else { return }
        isLoading = true
                
        let readyOperation = BlockOperation { [weak self] in
            self?.isLoading = false

            // Verify that the LiveViewPoster has been removed.
            guard self?.posterImageView.superview == nil else { return }
            
            // After the scene is prepared, and all animations are loaded, transition to the run state.
            self?.scene.state = .run
        }
        
        for operation in loadingQueue.operations {
            readyOperation.addDependency(operation)
        }
        OperationQueue.main.addOperation(readyOperation)
    }
    
    fileprivate func performStartingFlyover() {
        let animationDuration = WorldConfiguration.introPanDuration
        cameraController?.resetCamera(duration: animationDuration)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) {
            self.startRunningSceneWhenReady()
            self.showControls(true)
            
            // Announce the initial contents of the `gridWorld`.
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, self.scene.gridWorld.speakableDescription)
            self.setVoiceOverForCurrentStatus(forceLayout: true)
        }
    }
    
    func configureViewForDevice() {
        // Grab the device from the scene view and interrogate it.
        #if (arch(i386) || arch(x86_64)) && os(iOS)
        // Setup for the sim
        scnView.contentScaleFactor = 1.5
        scnView.preferredFramesPerSecond = 30
        #else
        if let defaultDevice = scnView.device,
            defaultDevice.supportsFeatureSet(.iOS_GPUFamily2_v2) {
            scnView.antialiasingMode = .multisampling2X
        }
        else {
            // Assume we're in GL-land
            scnView.contentScaleFactor = 1.5
            scnView.preferredFramesPerSecond = 30
        }
        #endif
        
    }
    
    override var prefersStatusBarHidden: Bool {
        return true
    }
}

private var renderedFrameCount = 0
extension SceneController: SCNSceneRendererDelegate {
    func renderer(_ renderer: SCNSceneRenderer, didRenderScene _: SCNScene, atTime time: TimeInterval) {
        
        // Offset the camera to initially match the poster while allowing frames to be rendered.
        self.cameraController?.switchToPosterView()
        
        renderedFrameCount += 1
        guard renderedFrameCount > WorldConfiguration.Scene.warmupFrameCount else { return }
        
        // Release the delegate.
        scnView.delegate = nil

        DispatchQueue.main.async {
            self.posterImageView.removeFromSuperview()
            self.performStartingFlyover()
        }
    }
}

extension SceneController: CommandQueueDelegate {
    // MARK: CommandQueueDelegate
    
    func commandQueue(_ queue: CommandQueue, added command: Command) {}
    func commandQueue(_ queue: CommandQueue, willPerform command: Command) {}
    
    func commandQueue(_ queue: CommandQueue, didPerform command: Command) {
        switch command.action {
        case .add(_),
             .remove(_) where command.performer is GridWorld:
            updateCounterLabelTotals()
            
        case .control(_), .remove(_):
            updateCounterLabelRunningCounts()
            
        default:
            break
        }
        
        // If the queue is finished, mark the scene as `.done`.
        if queue.isFinished {
            scene.state = .done
        }
    }
}
