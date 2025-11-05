import PhotosUI
import SwiftUI
import UIKit

struct ImagePicker: UIViewControllerRepresentable {
    enum Source {
        case camera
        case photoLibrary
    }

    @Binding var image: UIImage?
    let source: Source

    func makeUIViewController(context: Context) -> UIViewController {
        switch source {
        case .camera:
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.delegate = context.coordinator
            picker.allowsEditing = false
            return picker
        case .photoLibrary:
            var config = PHPickerConfiguration(photoLibrary: .shared())
            config.filter = .images
            config.selectionLimit = 1
            let picker = PHPickerViewController(configuration: config)
            picker.delegate = context.coordinator
            return picker
        }
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate, PHPickerViewControllerDelegate {
        let parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage {
                parent.image = img
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else {
                picker.dismiss(animated: true)
                return
            }
            provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                DispatchQueue.main.async {
                    self?.parent.image = object as? UIImage
                }
            }
            picker.dismiss(animated: true)
        }
    }
}
