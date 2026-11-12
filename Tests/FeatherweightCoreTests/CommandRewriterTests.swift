import Testing
@testable import FeatherweightCore

struct CommandRewriterTests {
    let scripts: Set<String> = ["build", "test", "lint", "deploy"]
    let bins: Set<String> = ["tsc", "eslint"]

    func npm(_ command: String) -> (String, uncertain: [String]) {
        CommandRewriter.rewrite(command, from: .npm, scripts: scripts, dependencyBins: bins)
    }

    func yarn(_ command: String) -> (String, uncertain: [String]) {
        CommandRewriter.rewrite(command, from: .yarn, scripts: scripts, dependencyBins: bins)
    }

    // MARK: Command table, one test per row

    @Test func npmCi() {
        #expect(npm("npm ci") == ("pnpm install --frozen-lockfile", []))
    }

    @Test func npmInstallWithoutArgs() {
        #expect(npm("npm install") == ("pnpm install", []))
        #expect(npm("npm i") == ("pnpm install", []))
    }

    @Test func npmRun() {
        #expect(npm("npm run build") == ("pnpm run build", []))
        #expect(npm("npm run test -- --watch") == ("pnpm run test -- --watch", []))
        #expect(npm("npm run-script lint") == ("pnpm run lint", []))
    }

    @Test func npmTestAndStart() {
        #expect(npm("npm test") == ("pnpm test", []))
        #expect(npm("npm start") == ("pnpm start", []))
    }

    @Test func npmPrefix() {
        #expect(npm("npm --prefix functions run build") == ("pnpm --dir functions run build", []))
        #expect(npm("npm run build --prefix functions") == ("pnpm --dir functions run build", []))
        #expect(npm("npm --prefix \"$RESOURCE_DIR\" run lint") == ("pnpm --dir \"$RESOURCE_DIR\" run lint", []))
    }

    @Test func npxDependencyBin() {
        #expect(npm("npx tsc --noEmit") == ("pnpm exec tsc --noEmit", []))
    }

    @Test func npxOtherwiseDlx() {
        #expect(npm("npx firebase deploy --only hosting") == ("pnpm dlx firebase deploy --only hosting", []))
        #expect(npm("npx -y serve dist") == ("pnpm dlx serve dist", []))
    }

    @Test func yarnInstall() {
        #expect(yarn("yarn") == ("pnpm install", []))
        #expect(yarn("yarn install") == ("pnpm install", []))
    }

    @Test func yarnFrozenOrImmutable() {
        #expect(yarn("yarn install --frozen-lockfile") == ("pnpm install --frozen-lockfile", []))
        #expect(yarn("yarn install --immutable") == ("pnpm install --frozen-lockfile", []))
    }

    @Test func yarnScript() {
        #expect(yarn("yarn run build") == ("pnpm run build", []))
        #expect(yarn("yarn build") == ("pnpm run build", []))
        #expect(yarn("yarn lint --fix") == ("pnpm run lint --fix", []))
    }

    @Test func yarnDlx() {
        #expect(yarn("yarn dlx create-vite app") == ("pnpm dlx create-vite app", []))
    }

    // MARK: Uncertain and chained commands

    @Test func uncertainInstallWithArgs() {
        let command = "rm -rf /tmp/fb-install && npm install firebase-functions@6.6.0 firebase-admin@13.10.0"
            + " --prefix /tmp/fb-install && cp -r /tmp/fb-install/node_modules functions/"
        let (rewritten, uncertain) = npm(command)
        #expect(rewritten == command)
        #expect(uncertain == ["npm install firebase-functions@6.6.0 firebase-admin@13.10.0 --prefix /tmp/fb-install"])
    }

    @Test func chainedCommands() {
        #expect(npm("npm run build && npx firebase deploy") == ("pnpm run build && pnpm dlx firebase deploy", []))
    }

    @Test func everySeparatorSplits() {
        #expect(npm("npm ci; npm test || echo failed | tee log")
            == ("pnpm install --frozen-lockfile; pnpm test || echo failed | tee log", []))
    }

    @Test func separatorsInsideQuotesDoNotSplit() {
        #expect(npm("echo \"a && npm ci\" && npm ci") == ("echo \"a && npm ci\" && pnpm install --frozen-lockfile", []))
    }

    @Test func unknownSubcommandsAreUncertain() {
        #expect(npm("npm publish --access public") == ("npm publish --access public", ["npm publish --access public"]))
        #expect(yarn("yarn add left-pad") == ("yarn add left-pad", ["yarn add left-pad"]))
        #expect(npm("npm run build --silent") == ("npm run build --silent", ["npm run build --silent"]))
    }

    @Test func environmentAssignmentsAreKept() {
        #expect(npm("NODE_ENV=production npm run build") == ("NODE_ENV=production pnpm run build", []))
    }

    @Test func npmNotFirstIsUncertain() {
        let command = "cross-env NODE_ENV=production npm run build"
        #expect(npm(command) == (command, [command]))
    }

    @Test func otherCommandsAreUntouchedAndNotUncertain() {
        #expect(npm("rm -rf dist && echo done") == ("rm -rf dist && echo done", []))
    }

    @Test func npmAfterCdIsUncertain() {
        let command = "cd functions && npm ci"
        #expect(npm(command) == (command, ["npm ci"]))
        #expect(npm("cd . && npm ci") == ("cd . && pnpm install --frozen-lockfile", []))
    }
}
