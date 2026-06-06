import KeyboardKit
import UIKit

class CustomActionHandler: KeyboardAction.StandardActionHandler {
    private let pttController: PTTController

    init(pttController: PTTController, inputController: KeyboardInputViewController) {
        self.pttController = pttController
        let state = inputController.state
        let services = inputController.services
        super.init(
            controller: inputController,
            keyboardContext: state.keyboardContext,
            keyboardBehavior: services.keyboardBehavior,
            autocompleteContext: state.autocompleteContext,
            autocompleteService: services.autocompleteService,
            emojiContext: state.emojiContext,
            feedbackContext: state.feedbackContext,
            feedbackService: services.feedbackService,
            keyboardAppContext: state.keyboardAppContext,
            spacebarDragGestureHandler: services.spacebarDragGestureHandler
        )
    }

    override func handle(_ gesture: Keyboard.Gesture, on action: KeyboardAction) {
        if case .custom(let name) = action, name == "corvin_mic" {
            handleMicGesture(gesture)
            return
        }
        super.handle(gesture, on: action)
    }

    private func handleMicGesture(_ gesture: Keyboard.Gesture) {
        switch gesture {
        case .press:
            if !pttController.isRecording && !pttController.isTranscribing && pttController.lastError == nil {
                pttController.startRecording()
            }
        case .release:
            if pttController.isRecording {
                pttController.stopRecording()
            }
            if pttController.lastError != nil {
                pttController.lastError = nil
            }
        default:
            break
        }
    }
}
