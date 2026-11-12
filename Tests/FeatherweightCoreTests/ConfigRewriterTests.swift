import Foundation
import Testing
@testable import FeatherweightCore

struct ConfigRewriterTests {
    let rewriter = ConfigRewriter()

    func context(
        scripts: Set<String> = ["build", "test"], bins: Set<String> = [], lockfile: String = "package-lock.json",
        packageManagerField: Bool = true
    ) -> RewriteContext {
        RewriteContext(
            scripts: scripts, dependencyBins: bins, oldLockfile: lockfile, pnpmVersion: "10.33.2",
            packageManagerField: packageManagerField)
    }

    // MARK: Workflows

    @Test func workflowInsertsActionSetupAndCache() {
        let input = """
        name: CI
        on: push
        jobs:
          test:
            runs-on: ubuntu-latest
            steps:
              - uses: actions/checkout@v4
              - uses: actions/setup-node@v4
                with:
                  node-version: 22
                  cache: 'npm'
              - run: npm ci
              - run: npm test

        """
        let expected = """
        name: CI
        on: push
        jobs:
          test:
            runs-on: ubuntu-latest
            steps:
              - uses: actions/checkout@v4
              - uses: pnpm/action-setup@v4
              - uses: actions/setup-node@v4
                with:
                  node-version: 22
                  cache: pnpm
              - run: pnpm install --frozen-lockfile
              - run: pnpm test

        """
        let result = rewriter.rewriteWorkflow(
            text: input, file: ".github/workflows/ci.yml", from: .npm, context: context())
        #expect(result.rewritten == expected)
        #expect(result.warnings.isEmpty)
        #expect(result.relativePath == ".github/workflows/ci.yml")
    }

    @Test func workflowPinsPnpmMajorWithoutPackageManagerField() {
        let input = """
        steps:
          - name: Node
            uses: actions/setup-node@v4
            with:
              cache: yarn
              cache-dependency-path: '**/yarn.lock'
          - run: |
              yarn install --frozen-lockfile
              yarn build

        """
        let expected = """
        steps:
          - uses: pnpm/action-setup@v4
            with:
              version: 10
          - name: Node
            uses: actions/setup-node@v4
            with:
              cache: pnpm
              cache-dependency-path: '**/pnpm-lock.yaml'
          - run: |
              pnpm install --frozen-lockfile
              pnpm run build

        """
        let result = rewriter.rewriteWorkflow(
            text: input, file: "ci.yml", from: .yarn,
            context: context(lockfile: "yarn.lock", packageManagerField: false))
        #expect(result.rewritten == expected)
        #expect(result.warnings.isEmpty)
    }

    @Test func workflowWithActionSetupAlreadyIsNotDoubled() {
        let input = "steps:\n  - uses: pnpm/action-setup@v4\n  - uses: actions/setup-node@v4\n  - run: npm ci\n"
        let result = rewriter.rewriteWorkflow(text: input, file: "ci.yml", from: .npm, context: context())
        #expect(result.rewritten == "steps:\n  - uses: pnpm/action-setup@v4\n  - uses: actions/setup-node@v4\n  - run: pnpm install --frozen-lockfile\n")
    }

    @Test func workflowWarnsWithoutSetupNode() {
        let input = "jobs:\n  t:\n    steps:\n      - uses: actions/checkout@v4\n      - run: npm ci\n"
        let result = rewriter.rewriteWorkflow(text: input, file: "ci.yml", from: .npm, context: context())
        #expect(result.rewritten == input.replacingOccurrences(of: "npm ci", with: "pnpm install --frozen-lockfile"))
        #expect(result.warnings.count == 1)
        #expect(result.warnings.first?.line == 5)
        #expect(result.warnings.first?.text.contains("setup-node") == true)
    }

    @Test func workflowStepInAnotherDirectoryIsUncertain() {
        let input = """
        steps:
          - uses: actions/setup-node@v4
          - run: npm ci
          - name: Functions
            working-directory: functions
            run: npm ci

        """
        let result = rewriter.rewriteWorkflow(text: input, file: "ci.yml", from: .npm, context: context())
        #expect(result.rewritten.contains("  - run: pnpm install --frozen-lockfile\n"))
        #expect(result.rewritten.contains("    run: npm ci\n"))
        #expect(result.warnings == [RewriteWarning(file: "ci.yml", line: 7, text: "npm ci")])
    }

    // MARK: Dockerfile

    @Test func dockerfileRewrite() {
        let input = """
        FROM node:22-alpine
        WORKDIR /app
        COPY package.json package-lock.json ./
        RUN npm ci
        COPY . .
        RUN npm run build
        CMD ["node", "dist/server.js"]

        """
        let expected = """
        FROM node:22-alpine
        WORKDIR /app
        COPY package.json pnpm-lock.yaml ./
        RUN corepack enable && pnpm install --frozen-lockfile
        COPY . .
        RUN pnpm run build
        CMD ["node", "dist/server.js"]

        """
        let result = rewriter.rewriteDockerfile(text: input, file: "Dockerfile", from: .npm, context: context())
        #expect(result.rewritten == expected)
        #expect(result.warnings.isEmpty)
    }

    @Test func dockerfileGlobCopyGainsLockfile() {
        let input = "COPY package*.json ./\nRUN npm install\n"
        let result = rewriter.rewriteDockerfile(text: input, file: "Dockerfile", from: .npm, context: context())
        #expect(result.rewritten
            == "COPY package*.json pnpm-lock.yaml ./\nRUN corepack enable && pnpm install --frozen-lockfile\n")
    }

    @Test func dockerfileWarnsWhenPnpmIsNotEnabledFirst() {
        let input = "FROM node:22\nRUN npm run build\n"
        let result = rewriter.rewriteDockerfile(text: input, file: "Dockerfile", from: .npm, context: context())
        #expect(result.rewritten == "FROM node:22\nRUN pnpm run build\n")
        #expect(result.warnings.map(\.line) == [2])
    }

    @Test func dockerfileContinuationLines() {
        let input = "RUN npm ci \\\n    && npm run build\n"
        let result = rewriter.rewriteDockerfile(text: input, file: "Dockerfile", from: .npm, context: context())
        #expect(result.rewritten
            == "RUN corepack enable && pnpm install --frozen-lockfile \\\n    && pnpm run build\n")
        #expect(result.warnings.isEmpty)
    }

    // MARK: JSON and TOML

    @Test func firebasePredeploy() {
        let input = """
        {
          "functions": {
            "predeploy": [
              "npm --prefix \\"$RESOURCE_DIR\\" run lint",
              "npm --prefix \\"$RESOURCE_DIR\\" run build"
            ],
            "source": "functions"
          },
          "hosting": { "public": "dist", "predeploy": "npm run build" }
        }

        """
        let expected = """
        {
          "functions": {
            "predeploy": [
              "pnpm --dir \\"$RESOURCE_DIR\\" run lint",
              "pnpm --dir \\"$RESOURCE_DIR\\" run build"
            ],
            "source": "functions"
          },
          "hosting": { "public": "dist", "predeploy": "pnpm run build" }
        }

        """
        let result = rewriter.rewriteFirebase(text: input, file: "firebase.json", from: .npm, context: context())
        #expect(result.rewritten == expected)
        #expect(result.warnings.isEmpty)
    }

    @Test func packageJSONKeepsFormatting() {
        let input = """
        {
            "name": "app",
            "packageManager": "npm@10.9.2",
            "scripts": {
                "build": "npm run compile && npm run bundle",
                "compile": "tsc",
                "deploy": "npx firebase deploy"
            },
            "dependencies": { "npm": "1.0.0" }
        }

        """
        let expected = """
        {
            "name": "app",
            "packageManager": "pnpm@10.33.2",
            "scripts": {
                "build": "pnpm run compile && pnpm run bundle",
                "compile": "tsc",
                "deploy": "pnpm dlx firebase deploy"
            },
            "dependencies": { "npm": "1.0.0" }
        }

        """
        let result = rewriter.rewritePackageJSON(text: input, file: "package.json", from: .npm, context: context())
        #expect(result.rewritten == expected)
    }

    @Test func packageJSONNoPackageManagerFieldAdded() {
        let input = "{\n  \"name\": \"app\",\n  \"scripts\": { \"test\": \"npm run lint\" }\n}\n"
        let result = rewriter.rewritePackageJSON(text: input, file: "package.json", from: .npm, context: context())
        #expect(result.rewritten == "{\n  \"name\": \"app\",\n  \"scripts\": { \"test\": \"pnpm run lint\" }\n}\n")
        #expect(!result.rewritten.contains("packageManager"))
    }

    @Test func netlifyCommand() {
        let input = "[build]\n  command = \"npm run build\"\n  publish = \"dist\"\n[context.preview]\n  command = 'npx vite build'\n"
        let result = rewriter.rewriteNetlify(text: input, file: "netlify.toml", from: .npm, context: context())
        #expect(result.rewritten
            == "[build]\n  command = \"pnpm run build\"\n  publish = \"dist\"\n[context.preview]\n  command = 'pnpm dlx vite build'\n")
    }

    @Test func vercelInstallCommand() {
        let input = "{\n  \"installCommand\": \"npm ci\",\n  \"buildCommand\": \"npm run build\",\n  \"outputDirectory\": \"npm\"\n}\n"
        let result = rewriter.rewriteVercel(text: input, file: "vercel.json", from: .npm, context: context())
        #expect(result.rewritten
            == "{\n  \"installCommand\": \"pnpm install --frozen-lockfile\",\n  \"buildCommand\": \"pnpm run build\",\n  \"outputDirectory\": \"npm\"\n}\n")
    }

    @Test func warningCarriesFileAndLine() {
        let input = """
        {
          "scripts": {
            "build": "vite build",
            "deploy-app": "rm -rf /tmp/fb-install && npm install firebase-functions@6.6.0 --prefix /tmp/fb-install"
          }
        }

        """
        let result = rewriter.rewritePackageJSON(text: input, file: "package.json", from: .npm, context: context())
        #expect(result.rewritten == input)
        #expect(result.warnings == [RewriteWarning(
            file: "package.json", line: 4, text: "npm install firebase-functions@6.6.0 --prefix /tmp/fb-install")])
    }

    // MARK: Whole project

    @Test func rewriteProjectReturnsOnlyFilesThatChangeOrWarn() throws {
        let tree = try TempTree([
            "package.json": "{\n  \"scripts\": { \"build\": \"tsc\", \"check\": \"npx tsc --noEmit\" },\n  \"devDependencies\": { \"typescript\": \"5.0.0\" }\n}\n",
            "package-lock.json": "{}",
            "node_modules/typescript/package.json": "{ \"name\": \"typescript\", \"bin\": { \"tsc\": \"bin/tsc\" } }",
            ".github/workflows/ci.yml": "steps:\n  - uses: actions/setup-node@v4\n  - run: npm ci\n",
            ".github/workflows/notes.txt": "npm ci\n",
            ".github/workflows/lint.yaml": "steps:\n  - run: echo hi\n",
            "Dockerfile.prod": "COPY package-lock.json ./\n",
            "netlify.toml": "[build]\n  command = \"make\"\n",
        ])
        defer { tree.remove() }
        let rewrites = try rewriter.rewriteProject(root: tree.root, from: .npm, pnpmVersion: "10.33.2")
        #expect(rewrites.map(\.relativePath) == [".github/workflows/ci.yml", "Dockerfile.prod", "package.json"])
        let packageJSON = try #require(rewrites.first { $0.relativePath == "package.json" })
        #expect(packageJSON.rewritten.contains("\"check\": \"pnpm exec tsc --noEmit\""))
        let workflow = try #require(rewrites.first { $0.relativePath == ".github/workflows/ci.yml" })
        #expect(workflow.rewritten.contains("version: 10"))
        // Nothing is written: the converter applies rewrites itself.
        #expect(try String(contentsOf: tree.url("Dockerfile.prod"), encoding: .utf8) == "COPY package-lock.json ./\n")
    }
}
