import CoreData
import Foundation
import SwiftUI
import UIKit

extension AddCarbs {
    final class StateModel: BaseStateModel<AddCarbs.Provider> {
        @Injected() var carbsStorage: CarbsStorage!
        @Injected() var apsManager: APSManager!
        @Injected() var settings: SettingsManager!
        @Injected() var keychain: Keychain!
        @Injected() var visionService: OpenAIVisionServiceProtocol!
        @Published var carbs: Decimal = 0
        @Published var date = Date()
        @Published var protein: Decimal = 0
        @Published var fat: Decimal = 0
        @Published var carbsRequired: Decimal?
        @Published var useFPUconversion: Bool = true
        @Published var dish: String = ""
        @Published var selection: Presets?
        @Published var summation: [String] = []
        @Published var maxCarbs: Decimal = 250
        @Published var maxFat: Decimal = 250
        @Published var maxProtein: Decimal = 250
        @Published var note: String = ""
        @Published var isAnalyzingPhoto = false
        @Published var visionError: String?

        let coredataContext = CoreDataStack.shared.persistentContainer.viewContext

        override func subscribe() {
            subscribeSetting(\.useFPUconversion, on: $useFPUconversion) { useFPUconversion = $0 }
            carbsRequired = provider.suggestion?.carbsReq
            maxCarbs = settings.settings.maxCarbs
            maxFat = settings.settings.maxFat
            maxProtein = settings.settings.maxProtein
        }

        func add() {
            guard carbs > 0 || fat > 0 || protein > 0 else {
                showModal(for: nil)
                return
            }
            carbs = min(carbs, maxCarbs)

            carbsStorage.storeCarbs(
                [CarbsEntry(
                    id: UUID().uuidString,
                    createdAt: date,
                    carbs: carbs,
                    fat: fat,
                    protein: protein,
                    note: note,
                    enteredBy: CarbsEntry.manual,
                    isFPU: false, fpuID: nil
                )]
            )

            if settingsManager.settings.skipBolusScreenAfterCarbs {
                apsManager.determineBasalSync()
                showModal(for: nil)
            } else {
                showModal(for: .bolus(waitForSuggestion: true))
            }
        }

        func deletePreset() {
            if selection != nil {
                try? coredataContext.delete(selection!)
                try? coredataContext.save()
                carbs = 0
                fat = 0
                protein = 0
            }
            selection = nil
        }

        func removePresetFromNewMeal() {
            let a = summation.firstIndex(where: { $0 == selection?.dish! })
            if a != nil, summation[a ?? 0] != "" {
                summation.remove(at: a!)
            }
        }

        func addPresetToNewMeal() {
            let test: String = selection?.dish ?? "dontAdd"
            if test != "dontAdd" {
                summation.append(test)
            }
        }

        func addNewPresetToWaitersNotepad(_ dish: String) {
            summation.append(dish)
        }

        func addToSummation() {
            summation.append(selection?.dish ?? "")
        }

        func waitersNotepad() -> String {
            var filteredArray = summation.filter { !$0.isEmpty }

            if carbs == 0, protein == 0, fat == 0 {
                filteredArray = []
            }

            guard filteredArray != [] else {
                return ""
            }
            var carbs_: Decimal = 0.0
            var fat_: Decimal = 0.0
            var protein_: Decimal = 0.0
            var presetArray = [Presets]()

            coredataContext.performAndWait {
                let requestPresets = Presets.fetchRequest() as NSFetchRequest<Presets>
                try? presetArray = coredataContext.fetch(requestPresets)
            }
            var waitersNotepad = [String]()
            var stringValue = ""

            for each in filteredArray {
                let countedSet = NSCountedSet(array: filteredArray)
                let count = countedSet.count(for: each)
                if each != stringValue {
                    waitersNotepad.append("\(count) \(each)")
                }
                stringValue = each

                for sel in presetArray {
                    if sel.dish == each {
                        carbs_ += (sel.carbs)! as Decimal
                        fat_ += (sel.fat)! as Decimal
                        protein_ += (sel.protein)! as Decimal
                        break
                    }
                }
            }
            let extracarbs = carbs - carbs_
            let extraFat = fat - fat_
            let extraProtein = protein - protein_
            var addedString = ""

            if extracarbs > 0, filteredArray.isNotEmpty {
                addedString += "Additional carbs: \(extracarbs) "
            } else if extracarbs < 0 { addedString += "Removed carbs: \(extracarbs) " }

            if extraFat > 0, filteredArray.isNotEmpty {
                addedString += "Additional fat: \(extraFat) "
            } else if extraFat < 0 { addedString += "Removed fat: \(extraFat) " }

            if extraProtein > 0, filteredArray.isNotEmpty {
                addedString += "Additional protein: \(extraProtein) "
            } else if extraProtein < 0 { addedString += "Removed protein: \(extraProtein) " }

            if addedString != "" {
                waitersNotepad.append(addedString)
            }
            var waitersNotepadString = ""

            if waitersNotepad.count == 1 {
                waitersNotepadString = waitersNotepad[0]
            } else if waitersNotepad.count > 1 {
                for each in waitersNotepad {
                    if each != waitersNotepad.last {
                        waitersNotepadString += " " + each + ","
                    } else { waitersNotepadString += " " + each }
                }
            }
            return waitersNotepadString
        }

        func saveButtonText() -> String {
            if carbs > maxCarbs {
                return "\(NSLocalizedString("Max Carbs of", comment: "")) \(maxCarbs) \(NSLocalizedString("g", comment: "")) \(NSLocalizedString("exceeded", comment: ""))"
            } else if fat > maxFat {
                return "\(NSLocalizedString("Max Fat of", comment: "")) \(maxFat) \(NSLocalizedString("g", comment: "")) \(NSLocalizedString("exceeded", comment: ""))"
            } else if protein > maxProtein {
                return "\(NSLocalizedString("Max Protein of", comment: "")) \(maxProtein) \(NSLocalizedString("g", comment: "")) \(NSLocalizedString("exceeded", comment: ""))"
            } else {
                return NSLocalizedString("Save and continue", comment: "")
            }
        }
        
        func analyzeMealPhoto(_ image: UIImage, completion: @escaping (String?) -> Void) {
            guard !isAnalyzingPhoto else { return }
            
            isAnalyzingPhoto = true
            visionError = nil
            
            // Get API key from keychain
            switch keychain.getValue(String.self, forKey: OpenAIConfig.Config.apiKeyKey) {
            case .success(let apiKey):
                guard let apiKey = apiKey, !apiKey.isEmpty else {
                    isAnalyzingPhoto = false
                    visionError = "OpenAI API key not configured. Please set it in Settings."
                    completion(visionError)
                    return
                }
                
                visionService.analyzeMealPhoto(image, apiKey: apiKey) { [weak self] result in
                    DispatchQueue.main.async {
                        self?.isAnalyzingPhoto = false
                        
                        switch result {
                        case .success(let nutrition):
                            self?.carbs = Decimal(nutrition.carbs)
                            self?.fat = Decimal(nutrition.fat)
                            self?.protein = Decimal(nutrition.protein)
                            self?.visionError = nil
                            completion(nil)
                        case .failure(let error):
                            self?.visionError = error.localizedDescription
                            completion(error.localizedDescription)
                        }
                    }
                }
            case .failure:
                isAnalyzingPhoto = false
                visionError = "Failed to retrieve API key from secure storage."
                completion(visionError)
            }
        }
    }
}
