import Foundation

struct ValidationRecipeDetector: Sendable {
    func detect(at repositoryURL: URL) async -> [ValidationRecipe] {
        await Task.detached(priority: .utility) {
            Self.detectSynchronously(at: repositoryURL)
        }.value
    }

    private static func detectSynchronously(
        at repositoryURL: URL
    ) -> [ValidationRecipe] {
        let fileManager = FileManager.default
        var recipes: [ValidationRecipe] = []

        if fileManager.fileExists(
            atPath: repositoryURL.appendingPathComponent("Package.swift").path
        ) {
            recipes += [
                ValidationRecipe(
                    kind: .build,
                    name: "Swift Build",
                    executablePath: "/usr/bin/xcrun",
                    arguments: ["swift", "build"],
                    timeoutSeconds: 900
                ),
                ValidationRecipe(
                    kind: .test,
                    name: "Swift Tests",
                    executablePath: "/usr/bin/xcrun",
                    arguments: ["swift", "test"],
                    timeoutSeconds: 1_200
                )
            ]
        }

        let packageJSON = repositoryURL.appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: packageJSON),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = object["scripts"] as? [String: Any],
           let npmPath = ExecutableResolver.first(named: ["npm"]) {
            if scripts["build"] is String {
                recipes.append(
                    ValidationRecipe(
                        kind: .build,
                        name: "npm Build",
                        executablePath: npmPath,
                        arguments: ["run", "build"],
                        timeoutSeconds: 900
                    )
                )
            }
            if scripts["test"] is String {
                recipes.append(
                    ValidationRecipe(
                        kind: .test,
                        name: "npm Tests",
                        executablePath: npmPath,
                        arguments: ["test"],
                        timeoutSeconds: 1_200
                    )
                )
            }
        }

        let gradleWrapper = repositoryURL.appendingPathComponent("gradlew")
        if fileManager.isExecutableFile(atPath: gradleWrapper.path) {
            recipes += [
                ValidationRecipe(
                    kind: .build,
                    name: "Gradle Build",
                    executablePath: gradleWrapper.path,
                    arguments: ["build"],
                    timeoutSeconds: 1_200
                ),
                ValidationRecipe(
                    kind: .test,
                    name: "Gradle Tests",
                    executablePath: gradleWrapper.path,
                    arguments: ["test"],
                    timeoutSeconds: 1_200
                )
            ]
        }

        let hasPythonTests = fileManager.fileExists(
            atPath: repositoryURL.appendingPathComponent("pytest.ini").path
        ) || fileManager.fileExists(
            atPath: repositoryURL.appendingPathComponent("pyproject.toml").path
        ) || fileManager.fileExists(
            atPath: repositoryURL.appendingPathComponent("tests", isDirectory: true).path
        )
        if hasPythonTests,
           let pythonPath = ExecutableResolver.first(
               named: ["python3", "python"]
           ) {
            recipes.append(
                ValidationRecipe(
                    kind: .test,
                    name: "Python Tests",
                    executablePath: pythonPath,
                    arguments: ["-m", "pytest"],
                    timeoutSeconds: 1_200
                )
            )
        }

        return recipes
    }
}
