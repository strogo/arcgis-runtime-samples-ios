// Copyright 2020 Esri
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import UIKit
import ArcGIS

class EditWithBranchVersioningViewController: UIViewController {
    // MARK: Storyboard views
    
    /// The label to display branch versioning status.
    @IBOutlet var statusLabel: UILabel!
    /// The button to create a version.
    @IBOutlet var createBarButtonItem: UIBarButtonItem!
    /// The button to switch to a version.
    @IBOutlet var switchBarButtonItem: UIBarButtonItem!
    
    /// The map view managed by the view controller.
    @IBOutlet var mapView: AGSMapView! {
        didSet {
            mapView.map = AGSMap(basemap: .streetsVector())
            mapView.touchDelegate = self
            mapView.callout.delegate = self
        }
    }
    
    // MARK: Properties
    
    /// The geodatabase's default branch version name.
    var defaultVersionName: String!
    /// The geodatabase's existing version names.
    /// - Note: To get a full list of versions, use `AGSServiceGeodatabase.fetchVersions(completion:)`.
    ///         In this sample, only the default version and versions created in current session are shown.
    var existingVersionNames = [String]() {
        didSet {
            if existingVersionNames.count > 1 {
                switchBarButtonItem.isEnabled = true
            }
        }
    }
    /// The name of the branch that the user is currently on.
    var currentVersionName: String! {
        willSet(newValue) {
            // When the service has internal error, it might give empty version name.
            if newValue != nil && !newValue.isEmpty {
                DispatchQueue.main.async { self.setStatus(message: newValue) }
            }
        }
    }
    
    /// The service geodatabase to demo branch versioning.
    var serviceGeodatabase: AGSServiceGeodatabase!
    /// A feature layer to display damaged building features.
    var featureLayer: AGSFeatureLayer!
    /// A reference to current selected feature.
    var selectedFeature: AGSFeature?
    /// A reference to the cancelable identify layer operation.
    var identifyOperation: AGSCancelable?
    
    /// Possible values for the service's "typdamage" attribute.
    private enum DamageType: String, CaseIterable {
        case destroyed = "Destroyed"
        case major = "Major"
        case minor = "Minor"
        case affected = "Affected"
        case inaccessible = "Inaccessible"
        case `default` = "Default"
    }
    
    // MARK: Methods
    
    /// Load service geodatabase from a feature service URL.
    ///
    /// - Parameter serviceURL: The URL to the feature service.
    /// - Returns: An `AGSServiceGeodatabase` object.
    func loadServiceGeodatabase(from serviceURL: URL) -> AGSServiceGeodatabase {
        let serviceGeodatabase = AGSServiceGeodatabase(url: serviceURL)
        // If not explicitly set, the service geodatabase will ask for credentials on loading.
        // You can also set its `credential` property. E.g.
        // serviceGeodatabase.credential = AGSCredential(user: "editor01", password: "editor01.password")
        
        SVProgressHUD.show(withStatus: "Loading service geodatabase…")
        serviceGeodatabase.load { [weak self] error in
            SVProgressHUD.dismiss()
            guard let self = self else { return }
            if serviceGeodatabase.loadStatus == .loaded {
                // Load with default version.
                self.defaultVersionName = serviceGeodatabase.defaultVersionName
                self.existingVersionNames.append(serviceGeodatabase.defaultVersionName)
                
                // Load feature layer.
                let featureLayer = self.loadFeatureLayer(with: serviceGeodatabase.table(withLayerID: 0)!) {
                    // After the feature layer is loaded, switch to default version.
                    self.switchVersion(geodatabase: serviceGeodatabase, to: serviceGeodatabase.defaultVersionName)
                }
                self.featureLayer = featureLayer
                self.mapView.map?.operationalLayers.add(featureLayer)
            } else if let error = error {
                self.presentAlert(error: error)
                self.setStatus(message: "Error loading service geodatabase.")
            }
        }
        return serviceGeodatabase
    }
    
    /// Load a feature layer with a feature table.
    ///
    /// - Parameters:
    ///   - featureTable: The feature table for creating the feature layer.
    ///   - completion: An optional closure to execute after feature layer is successfully loaded.
    /// - Returns: An `AGSFeatureLayer` object.
    func loadFeatureLayer(with featureTable: AGSFeatureTable, completion: (() -> Void)? = nil) -> AGSFeatureLayer {
        let featureLayer = AGSFeatureLayer(featureTable: featureTable)
        
        SVProgressHUD.show(withStatus: "Loading feature layer…")
        featureLayer.load { [weak self] error in
            SVProgressHUD.dismiss()
            if let extent = featureLayer.fullExtent {
                // Zoom to the target extent with animation.
                self?.mapView.setViewpoint(AGSViewpoint(targetExtent: extent), completion: nil)
                self?.createBarButtonItem.isEnabled = true
                completion?()
            } else if let error = error {
                self?.presentAlert(error: error)
            }
        }
        return featureLayer
    }
    
    /// Identify a tapped point on a feature layer.
    ///
    /// - Parameters:
    ///   - featureLayer: The feature layer where to identify the features.
    ///   - screenPoint: The tapped screen point.
    ///   - completion: A closure to pass the identified feature for further usage.
    func identifyPixel(on featureLayer: AGSFeatureLayer, at screenPoint: CGPoint, completion: @escaping (AGSFeature) -> Void) {
        // Clear selection before identify.
        clearSelection()
        // Clear in-progress identify operation.
        identifyOperation?.cancel()
        identifyOperation = nil
        // Identify the tapped feature.
        identifyOperation = mapView.identifyLayer(featureLayer, screenPoint: screenPoint, tolerance: 10.0, returnPopupsOnly: false) { [weak self] identifyResult in
            guard let self = self else { return }
            guard !identifyResult.geoElements.isEmpty, let firstFeature = identifyResult.geoElements.first as? AGSFeature else {
                return
            }
            self.featureLayer.select(firstFeature)
            self.selectedFeature = firstFeature
            completion(firstFeature)
        }
    }
    
    /// Create service parameters with provided information.
    ///
    /// - Parameters:
    ///   - accessPermission: An `AGSVersionAccess` object that defines the permission level.
    ///   - uniqueName: A unique string as branch version name.
    ///   - description: An optional string to describe the branch.
    /// - Returns: An `AGSServiceVersionParameters` object.
    func createServiceParameters(accessPermission: AGSVersionAccess, uniqueName: String, description: String?) -> AGSServiceVersionParameters {
        let parameters = AGSServiceVersionParameters()
        parameters.access = accessPermission
        parameters.name = uniqueName
        if let description = description {
            parameters.parametersDescription = description
        }
        return parameters
    }
    
    /// Create a new branch version with parameters in the service geodatabase.
    ///
    /// - Parameters:
    ///   - geodatabase: The geodatabase to create the version.
    ///   - parameters: The parameters for the new branch version.
    ///   - completion: The results for `AGSServiceGeodatabase.createVersion(with:completion:)` call.
    func createVersion(geodatabase: AGSServiceGeodatabase, with parameters: AGSServiceVersionParameters, completion: @escaping (Result<String, Error>) -> Void) {
        geodatabase.createVersion(with: parameters) { serviceVersionInfo, error in
            if let info = serviceVersionInfo {
                // Create version succeeded.
                completion(.success(info.name))
            } else if let error = error {
                // Failed to create version.
                completion(.failure(error))
            }
        }
    }
    
    /// Switch the geodatabase to connect to a new branch version.
    ///
    /// - Parameters:
    ///   - geodatabase: The geodatabase to connect switch version.
    ///   - branchVersionName: The new branch version name to connect to.
    func switchVersion(geodatabase: AGSServiceGeodatabase, to branchVersionName: String) {
        if currentVersionName == defaultVersionName {
            // Discard local edits if currently on default branch.
            undoLocalEdits(geodatabase: geodatabase) {
                geodatabase.switchVersion(withName: branchVersionName) { [weak self] error in
                    guard let self = self else { return }
                    if let error = error {
                        self.presentAlert(error: error)
                    } else {
                        // Reload feature table with the new version.
                        self.featureLayer.featureTable?.load()
                        self.currentVersionName = branchVersionName
                    }
                }
            }
        } else {
            // Apply local edits when switching to a user created branch.
            applyLocalEdits(geodatabase: geodatabase) {
                geodatabase.switchVersion(withName: branchVersionName) { [weak self] error in
                    guard let self = self else { return }
                    if let error = error {
                        self.presentAlert(error: error)
                    } else {
                        // Reload feature table with the new version.
                        self.featureLayer.featureTable?.load()
                        self.currentVersionName = branchVersionName
                    }
                }
            }
        }
    }
    
    /// Apply local edits to the geodatabase.
    ///
    /// - Parameters:
    ///   - geodatabase: The geodatabase to apply edits.
    ///   - completion: An optional closure to execute after edits are applied.
    func applyLocalEdits(geodatabase: AGSServiceGeodatabase, completion: (() -> Void)? = nil) {
        if geodatabase.hasLocalEdits() {
            SVProgressHUD.show(withStatus: "Applying local edits…")
            geodatabase.applyEdits { _, _ in
                SVProgressHUD.dismiss()
                completion?()
            }
        } else {
            completion?()
        }
    }
    
    /// Undo local edits on the geodatabase.
    ///
    /// - Parameters:
    ///   - geodatabase: The geodatabase to discard edits.
    ///   - completion: An optional closure to execute after edits are undone.
    func undoLocalEdits(geodatabase: AGSServiceGeodatabase, completion: (() -> Void)? = nil) {
        if geodatabase.hasLocalEdits() {
            SVProgressHUD.show(withStatus: "Discarding local edits…")
            geodatabase.undoLocalEdits { _ in
                SVProgressHUD.dismiss()
                completion?()
            }
        } else {
            completion?()
        }
    }
    
    // MARK: Actions
    
    @IBAction func createBarButtonItemTapped(_ sender: UIBarButtonItem) {
        chooseVersionAccessPermission(sender) { permission in
            self.createBranchAlert(permission: permission) { [weak self] parameters in
                guard let self = self else { return }
                self.createVersion(geodatabase: self.serviceGeodatabase, with: parameters) { [weak self] result in
                    guard let self = self else { return }
                    switch result {
                    case .success(let versionName):
                        self.existingVersionNames.append(versionName)
                        // Switch to the new version after it is created.
                        self.switchVersion(geodatabase: self.serviceGeodatabase, to: versionName)
                    case .failure(let error as NSError):
                        // Provide additional error reason to users if there is any.
                        let errorMessage = error.localizedDescription + (error.localizedFailureReason ?? "")
                        self.presentAlert(title: "Error", message: errorMessage)
                        self.setStatus(message: "Error creating new version.")
                    }
                }
            }
        }
    }
    
    @IBAction func switchBarButtonItemTapped(_ sender: UIBarButtonItem) {
        // Clear selection before switching to a new branch version.
        clearSelection()
        chooseVersion(sender) { versionName in
            self.switchVersion(geodatabase: self.serviceGeodatabase, to: versionName)
        }
    }
    
    // MARK: UI
    
    func clearSelection() {
        if let feature = selectedFeature {
            featureLayer.unselectFeature(feature)
            selectedFeature = nil
        }
    }
    
    func setStatus(message: String) {
        statusLabel.text = message
    }
    
    func showCallout(for feature: AGSFeature, tapLocation: AGSPoint?) {
        let placeName = feature.attributes["placename"] as? String
        mapView.callout.title = placeName
        mapView.callout.show(for: feature, tapLocation: tapLocation, animated: true)
    }
    
    /// Move the currently selected feature to the given map point, by updating the selected feature's geometry and feature table.
    func moveFeature(feature: AGSFeature, to mapPoint: AGSPoint) {
        // Create an alert to confirm that the user wants to update the geometry.
        let alert = UIAlertController(
            title: "Confirm Update",
            message: "Do you want to move the selected feature?",
            preferredStyle: .alert
        )
        // Clear the selection and selected feature on cancel.
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel) { _ in
            self.clearSelection()
        }
        // Move the feature to new geometry.
        let moveAction = UIAlertAction(title: "Move", style: .default) { _ in
            // Set the selected feature's geometry to the new map point.
            feature.geometry = mapPoint
            // Update the selected feature's feature table.
            feature.featureTable?.update(feature) { _ in
                self.clearSelection()
            }
        }
        alert.addAction(cancelAction)
        alert.addAction(moveAction)
        present(alert, animated: true)
    }
    
    func createBranchAlert(permission: AGSVersionAccess, completion: @escaping (AGSServiceVersionParameters) -> Void) {
        // Create an object to observe changes from the text fields.
        var textFieldObserver: NSObjectProtocol!
        // An alert to get user input for branch name and description.
        let alertController = UIAlertController(
            title: "Create branch version",
            message: "Please provide a branch name and a description.",
            preferredStyle: .alert
        )
        // Remove observer on cancel.
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel) { _ in
            NotificationCenter.default.removeObserver(textFieldObserver!)
        }
        // Create a new version and remove observer.
        let createAction = UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            guard let self = self else { return }
            NotificationCenter.default.removeObserver(textFieldObserver!)
            let branchTextField = alertController.textFields![0]
            let descriptionTextField = alertController.textFields![1]
            // If the text field is empty, do nothing.
            guard let branchText = branchTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines), !branchText.isEmpty else { return }
            let descriptionText = descriptionTextField.text
            let parameters = self.createServiceParameters(accessPermission: permission, uniqueName: branchText, description: descriptionText)
            completion(parameters)
        }
        createAction.isEnabled = false
        alertController.addAction(cancelAction)
        alertController.addAction(createAction)
        alertController.preferredAction = createAction
        
        // The text field for version name.
        alertController.addTextField { textField in
            textField.placeholder = "Version name must be unique"
            textField.delegate = self
            textFieldObserver = NotificationCenter.default.addObserver(
                forName: UITextField.textDidChangeNotification,
                object: textField,
                queue: .main
            ) { _ in
                let text = alertController.textFields?[0].text?.trimmingCharacters(in: .whitespacesAndNewlines)
                // Enable the done button if
                // 1. branch version textfield is not empty.
                let notEmpty = text?.isEmpty == false
                // 2. branch version string does not exceed 62 characters.
                let noLongerThan62Characters = text?.count ?? 0 <= 62
                createAction.isEnabled = notEmpty && noLongerThan62Characters
            }
        }
        // The text field for version description.
        alertController.addTextField { textField in
            textField.placeholder = "Branch version description here"
        }
        present(alertController, animated: true)
    }
    
    func editFeatureDamageAttribute(feature: AGSFeature, sourceRect: CGRect) {
        let alertController = UIAlertController(
            title: "Choose a damage type for the building",
            message: nil,
            preferredStyle: .actionSheet
        )
        DamageType.allCases.forEach { type in
            let action = UIAlertAction(title: type.rawValue, style: .default) { _ in
                feature.attributes["typdamage"] = type.rawValue
                feature.featureTable?.update(feature)
                self.mapView.callout.dismiss()
            }
            alertController.addAction(action)
        }
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel) { _ in
            self.mapView.callout.dismiss()
        }
        alertController.addAction(cancelAction)
        alertController.popoverPresentationController?.sourceView = view
        alertController.popoverPresentationController?.sourceRect = sourceRect
        // Hide the arrow as we cannot get the exact location of the accessory button.
        alertController.popoverPresentationController?.permittedArrowDirections = []
        present(alertController, animated: true)
    }
    
    func chooseVersion(_ sender: UIBarButtonItem, completion: @escaping (String) -> Void) {
        let alertController = UIAlertController(
            title: "Choose to switch to another version",
            message: nil,
            preferredStyle: .actionSheet
        )
        existingVersionNames.forEach { name in
            let action = UIAlertAction(title: name, style: .default) { _ in
                completion(name)
            }
            alertController.addAction(action)
        }
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)
        alertController.addAction(cancelAction)
        alertController.popoverPresentationController?.barButtonItem = sender
        present(alertController, animated: true)
    }
    
    func chooseVersionAccessPermission(_ sender: UIBarButtonItem, completion: @escaping (AGSVersionAccess) -> Void) {
        let alertController = UIAlertController(
            title: "Choose an access level for the new branch version",
            message: nil,
            preferredStyle: .actionSheet
        )
        let versionAccessPermission: KeyValuePairs<String, AGSVersionAccess> = [
            "Public": .public,
            "Protected": .protected,
            "Private": .private
        ]
        versionAccessPermission.forEach { name, permission in
            let action = UIAlertAction(title: name, style: .default) { _ in
                completion(permission)
            }
            alertController.addAction(action)
        }
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)
        alertController.addAction(cancelAction)
        alertController.popoverPresentationController?.barButtonItem = sender
        present(alertController, animated: true)
    }
    
    // MARK: UIViewController
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Add the source code button item to the right of navigation bar.
        (navigationItem.rightBarButtonItem as? SourceCodeBarButtonItem)?.filenames  = ["EditWithBranchVersioningViewController"]
        // Load the service geodatabase.
        let damageFeatureService = URL(string: "https://sampleserver7.arcgisonline.com/arcgis/rest/services/DamageAssessment/FeatureServer")!
        serviceGeodatabase = loadServiceGeodatabase(from: damageFeatureService)
    }
}

// MARK: - AGSGeoViewTouchDelegate

extension EditWithBranchVersioningViewController: AGSGeoViewTouchDelegate {
    func geoView(_ geoView: AGSGeoView, didTapAtScreenPoint screenPoint: CGPoint, mapPoint: AGSPoint) {
        // Disable interaction with features on default branch.
        if currentVersionName == defaultVersionName {
            return
        }
        // Dismiss any presenting callout.
        mapView.callout.dismiss()
        
        if let selectedFeature = selectedFeature {
            // If there is a feature selected already, tap elsewhere to move it.
            moveFeature(feature: selectedFeature, to: mapPoint)
        } else {
            // Tap to identify a pixel on the feature layer.
            identifyPixel(on: featureLayer, at: screenPoint) { feature in
                self.showCallout(for: feature, tapLocation: mapPoint)
            }
        }
    }
}

// MARK: - AGSCalloutDelegate

extension EditWithBranchVersioningViewController: AGSCalloutDelegate {
    func didTapAccessoryButton(for callout: AGSCallout) {
        // Show editing options actionsheet.
        let sourceRect = CGRect(origin: mapView.location(toScreen: callout.mapLocation!), size: .zero)
        editFeatureDamageAttribute(feature: selectedFeature!, sourceRect: sourceRect)
    }
}

// MARK: - UITextFieldDelegate

extension EditWithBranchVersioningViewController: UITextFieldDelegate {
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        let text = (textField.text! as NSString).replacingCharacters(in: range, with: string)
        // Must not include special characters: . ; ' "
        let invalidCharacters = ".;'\""
        return CharacterSet(charactersIn: invalidCharacters).isDisjoint(with: CharacterSet(charactersIn: text))
    }
}