// Jenkinsfile for dkms-verifier.
//
// What this job does:
//   1. Checks out the dkms-verifier repo (this file's repo).
//   2. Resolves $BRANCH to (TAG, BASE, HEAD) from the kernel git tree.
//   3. Pulls the module artifact produced by an upstream build job
//      via copyArtifacts.
//   4. Runs `make release-branch` to produce releases/<tag>/report.html.
//   5. Diffs against the previous release and archives both.
//
// Required Jenkins plugins:
//   - Pipeline                    (workflow)
//   - Git
//   - Copy Artifact
//   - HTML Publisher
//   - (optional) Slack Notification or Email Extension for notify
//
// Upstream job contract (configure UPSTREAM_JOB / UPSTREAM_ARTIFACT):
//   The upstream Jenkins job that builds the OOT kernel must archive a
//   single artifact that import_modules.sh recognises. Recommended shape:
//
//       linux-modules-<branch>.tar.zst   (or .tar.gz, .deb, .ddeb)
//
//   ...such that, once extracted, it contains
//       lib/modules/<ver>/kernel/...
//
// This dkms-verifier job is intentionally one job among many. It does NOT build
// the kernel. If the upstream artifact is missing, the build fails fast.

pipeline {
  agent { label params.AGENT_LABEL ?: 'linux && dkms-verifier' }

  options {
    timestamps()
    ansiColor('xterm')
    timeout(time: 30, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '50', artifactNumToKeepStr: '20'))
    disableConcurrentBuilds(abortPrevious: true)
  }

  parameters {
    // === inputs that change per run ===
    string(name: 'BRANCH',
           defaultValue: 'origin/6.18/linux',
           description: 'Kernel branch to evaluate. Must have a release tag at its tip ' +
                        '(lts-v*-linux-* or mainline-preprod-v*-linux-*).')

    string(name: 'KERNEL_SRC',
           defaultValue: '/srv/ci/kernel-lts-staging',
           description: 'Absolute path to the OOT kernel git tree on the agent.')

    string(name: 'UPSTREAM_JOB',
           defaultValue: 'kernel-build-oot',
           description: 'Jenkins job name that produced the modules artifact.')

    string(name: 'UPSTREAM_BUILD_SELECTOR',
           defaultValue: 'lastSuccessful',
           description: 'Build to copy from: lastSuccessful | latest | <build number>.')

    string(name: 'UPSTREAM_ARTIFACT_GLOB',
           defaultValue: 'linux-modules-*.tar.*',
           description: 'Artifact glob inside the upstream job. The first match is used.')

    // === knobs ===
    booleanParam(name: 'REFRESH_TARGETS',
                 defaultValue: false,
                 description: 'Re-fetch all Ubuntu KMI baselines listed in targets.conf (slow).')

    string(name: 'AGENT_LABEL',
           defaultValue: '',
           description: '(advanced) override the agent label.')
  }

  environment {
    // Make these visible to shell steps without quoting params.
    BRANCH      = "${params.BRANCH}"
    KERNEL_SRC  = "${params.KERNEL_SRC}"
    UPSTREAM    = "${params.UPSTREAM_JOB}"
    SELECTOR    = "${params.UPSTREAM_BUILD_SELECTOR}"
    ARTIFACT_GLOB = "${params.UPSTREAM_ARTIFACT_GLOB}"
    WORKSPACE_REL = '.'
  }

  stages {

    stage('Checkout dkms-verifier') {
      steps {
        checkout scm
      }
    }

    stage('Sanity check inputs') {
      steps {
        sh '''
          set -e
          test -d "$KERNEL_SRC/.git"     || { echo "KERNEL_SRC=$KERNEL_SRC is not a git tree"; exit 2; }
          test -f targets.conf            || { echo "targets.conf missing"; exit 2; }
          # Resolve the branch up front so we fail fast if no tag points there.
          ./scripts/resolve_branch.sh "$KERNEL_SRC" "$BRANCH"
        '''
      }
    }

    stage('Refresh Ubuntu targets') {
      when { expression { params.REFRESH_TARGETS } }
      steps { sh 'make refresh-targets' }
    }

    stage('Pull modules from upstream build') {
      steps {
        // Pull the upstream artifact tarball/deb into ./upstream/ .
        // Adjust filter / target / selector to your environment.
        copyArtifacts(
          projectName: env.UPSTREAM,
          selector: buildSelectorFromString(env.SELECTOR),
          filter: env.ARTIFACT_GLOB,
          target: 'upstream/',
          fingerprintArtifacts: true,
          flatten: true,
          optional: false
        )
        sh '''
          set -e
          ls -la upstream/
          # Pick the first match — there should be exactly one.
          ARTIFACT=$(ls -1 upstream/$ARTIFACT_GLOB 2>/dev/null | head -1)
          test -n "$ARTIFACT" || { echo "no artifact matched $ARTIFACT_GLOB"; exit 2; }
          echo "$ARTIFACT" > upstream/.selected
          echo "selected: $ARTIFACT"
        '''
      }
    }

    stage('Run dkms-verifier report') {
      steps {
        sh '''
          set -e
          ARTIFACT=$(cat upstream/.selected)
          make release-branch \
            BRANCH="$BRANCH" \
            SRC="$KERNEL_SRC" \
            ARTIFACT="$ARTIFACT"
        '''
      }
    }

    stage('Diff vs previous release') {
      steps {
        sh '''
          set -e
          # Find the tag this run produced.
          eval "$(./scripts/resolve_branch.sh "$KERNEL_SRC" "$BRANCH")"
          PREV=$(ls -1t releases/ \
                   | grep -v "^${TAG}$" \
                   | grep -vE "^(diff-|index)" \
                   | head -1 || true)
          if [ -n "$PREV" ]; then
            echo "Diffing $TAG against previous release: $PREV"
            ./scripts/diff_releases.sh "$PREV" "$TAG"
          else
            echo "No previous release to diff against."
          fi
        '''
      }
    }

    stage('Publish report') {
      steps {
        // Resolve TAG to its directory, then archive.
        sh '''
          set -e
          eval "$(./scripts/resolve_branch.sh "$KERNEL_SRC" "$BRANCH")"
          echo "$TAG" > .release-tag
        '''
        script {
          def tag = readFile('.release-tag').trim()
          archiveArtifacts artifacts: "releases/${tag}/**", fingerprint: true
          publishHTML(target: [
            allowMissing:          false,
            alwaysLinkToLastBuild: true,
            keepAll:               true,
            reportDir:             "releases/${tag}",
            reportFiles:           'report.html',
            reportName:            "ABI report (${tag})",
            includes:              'report.html,**/*.html,**/*.css'
          ])
        }
      }
    }
  }

  post {
    success {
      echo "dkms-verifier OK for branch ${env.BRANCH}"
    }
    failure {
      // Replace with your team's channel. Leave the echo as a fallback so
      // teams that don't have Slack/email plugins still see something.
      echo "dkms-verifier FAILED for branch ${env.BRANCH} — see console log."
      // slackSend channel: '#oot-kernel', color: 'danger',
      //           message: "dkms-verifier FAILED on ${env.BRANCH} (#${env.BUILD_NUMBER}): ${env.BUILD_URL}"
      // emailext to: 'kernel-oot@example.com',
      //          subject: "dkms-verifier FAILED: ${env.BRANCH} #${env.BUILD_NUMBER}",
      //          body: "${env.BUILD_URL}"
    }
    always {
      sh '''
        echo "--- artifact list ---"
        find releases/ -maxdepth 3 -type f 2>/dev/null | head -50 || true
      '''
    }
  }
}

// Helper: turn a string like "lastSuccessful" or "42" into the right
// CopyArtifact selector object.
def buildSelectorFromString(String sel) {
  switch (sel) {
    case 'lastSuccessful': return lastSuccessful()
    case 'latest':         return latestSavedBuild()
    default:               return specific(sel)
  }
}
