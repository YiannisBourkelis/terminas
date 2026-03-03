# Release Workflow

This document describes the branching strategy and release workflow for termiNAS.

## Branching Strategy

termiNAS uses a **two-branch workflow**:

- **`main` branch**: Stable releases only (protected)
  - Contains only tested, tagged releases
  - Users cloning get stable code by default
  - Never commit directly to `main`

- **`dev` branch**: Active development (default)
  - All feature development happens here
  - Tested but may contain unreleased features
  - Merged to `main` only for releases

## Version Numbering

termiNAS follows [Semantic Versioning](https://semver.org/):

- **Format**: MAJOR.MINOR.PATCH[-PRERELEASE]
- **Examples**: 
  - `1.0.0-alpha.1` - First alpha release
  - `1.0.0-alpha.2` - Second alpha release
  - `1.0.0-beta.1` - First beta release
  - `1.0.0` - First stable release
  - `1.1.0` - Minor feature addition
  - `1.1.1` - Patch/bugfix

## Daily Development Workflow

All development work happens in the `dev` branch:

```bash
# Ensure you're in dev branch
git checkout dev

# Make your changes
# ... edit files ...

# Commit changes
git add .
git commit -m "Description of changes"

# Push to GitHub
git push origin dev
```

## Release Workflow

When ready to create a new release, follow these steps:

### 1. Prepare Release in `dev` Branch

```bash
# Ensure you're in dev branch and up to date
git checkout dev
git pull origin dev

# Update VERSION file (single source of truth)
echo "1.0.0-alpha.2" > VERSION

# Update CHANGELOG.md
# Add new version section with changes since last release
nano CHANGELOG.md  # or your preferred editor

# Example CHANGELOG.md entry:
## [1.0.0-alpha.2] - 2025-10-25

### Added
- New feature description

### Changed
- Modification description

### Fixed
- Bug fix description
```

### 2. Create Release Notes File (Optional)

Create a detailed release notes file for this version:

```bash
# Create release notes file (see previous releases for format)
nano RELEASE_NOTES_v1.0.0-alpha.2.md
```

Include: release date, what's new, installation instructions, known issues, and testing checklist.

### 3. Commit Version Bump

```bash
# Stage the version changes
git add VERSION CHANGELOG.md RELEASE_NOTES_v1.0.0-alpha.2.md

# Commit with clear message
git commit -m "Bump version to 1.0.0-alpha.2

- Updated VERSION file
- Updated CHANGELOG.md with release notes
- Added RELEASE_NOTES_v1.0.0-alpha.2.md"
```

### 4. Merge to `main` Branch

```bash
# Switch to main branch
git checkout main

# Merge dev branch (use --no-edit to accept default merge message)
git merge dev --no-edit

# Verify everything looks correct
git log --oneline -5
git diff HEAD~1
```

### 5. Create Git Tag

```bash
# Create annotated tag with message
git tag -a v1.0.0-alpha.2 -m "Release v1.0.0-alpha.2

Brief description of major changes in this release.
See CHANGELOG.md for full details."

# Verify tag was created
git tag -l -n9 v1.0.0-alpha.2
```

### 6. Push to GitHub

```bash
# Push main branch and tags
git push origin main --tags
```

### 7. Return to `dev` Branch and Push

```bash
# Switch back to dev for continued development
git checkout dev

# Push dev branch (contains version bump commit)
git push origin dev
```

### 8. Create GitHub Release

1. Go to: https://github.com/YiannisBourkelis/terminas/releases/new
2. **Select tag**: `v1.0.0-alpha.2`
3. **Release title**: `termiNAS v1.0.0-alpha.2 - [Brief Description]`
4. **Description**: Copy content from `RELEASE_NOTES_v1.0.0-alpha.2.md` (or `CHANGELOG.md` if no release notes file)
5. **Pre-release**: Check if alpha/beta, uncheck if stable
6. **Click**: "Publish release"

## Complete Release Script

For convenience, here's the complete workflow in one script:

```bash
#!/bin/bash
# Quick release script (run from dev branch)

# Check if version argument provided
if [ -z "$1" ]; then
    echo "Usage: ./release.sh VERSION"
    echo "Example: ./release.sh 1.0.0-alpha.2"
    exit 1
fi

VERSION="$1"

# Ensure we're in dev branch
git checkout dev || exit 1

# Update VERSION file
echo "$VERSION" > VERSION

echo "VERSION file updated to $VERSION"
echo ""
echo "Now edit CHANGELOG.md and optionally create RELEASE_NOTES_v$VERSION.md"
echo "Press Enter when done..."
read

# Commit version bump
git add VERSION CHANGELOG.md
[ -f "RELEASE_NOTES_v$VERSION.md" ] && git add "RELEASE_NOTES_v$VERSION.md"
git commit -m "Bump version to $VERSION

- Updated VERSION file
- Updated CHANGELOG.md with release notes"

# Merge to main
git checkout main || exit 1
git merge dev --no-edit || exit 1

# Create tag
git tag -a "v$VERSION" -m "Release v$VERSION

See CHANGELOG.md for details."

# Push
git push origin main --tags

# Return to dev and push
git checkout dev
git push origin dev

echo ""
echo "✅ Release v$VERSION complete!"
echo ""
echo "Next steps:"
echo "1. Go to: https://github.com/YiannisBourkelis/terminas/releases/new"
echo "2. Select tag: v$VERSION"
echo "3. Create GitHub Release with RELEASE_NOTES or CHANGELOG.md content"
```

Save this as `release.sh` in the project root, make it executable:

```bash
chmod +x release.sh
```

Then use it like:

```bash
./release.sh 1.0.0-alpha.2
```

## Hotfix Workflow (Emergency Bug Fixes)

If you need to fix a critical bug in production without merging all dev changes:

```bash
# Create hotfix branch from main
git checkout main
git checkout -b hotfix/critical-bug

# Make the fix
# ... edit files ...

# Update VERSION (increment patch number)
echo "1.0.1" > VERSION

# Update CHANGELOG.md with hotfix entry
nano CHANGELOG.md

# Commit
git add .
git commit -m "Hotfix: Fix critical bug

Description of the bug and fix."

# Merge to main
git checkout main
git merge hotfix/critical-bug

# Tag
git tag -a v1.0.1 -m "Hotfix v1.0.1 - Critical bug fix"

# Push
git push origin main --tags

# Merge back to dev to keep it in sync
git checkout dev
git merge main

# Delete hotfix branch
git branch -d hotfix/critical-bug

# Return to dev
git checkout dev
```

## Branch Protection (Optional)

For added safety, consider protecting the `main` branch on GitHub:

1. Go to: Settings → Branches → Add branch protection rule
2. Branch name pattern: `main`
3. Enable:
   - ☑ Require pull request before merging
   - ☑ Require status checks to pass before merging (if you have CI/CD)
4. Save

This prevents accidental direct commits to `main`.

## Tips

- **Always test** in `dev` before releasing
- **Update CHANGELOG.md** with every notable change
- **Use descriptive commit messages** following conventional commits format
- **Tag releases** with detailed messages for future reference
- **Test the release** after tagging (clone the tag and verify it works)
- **Announce releases** on GitHub, forums, social media

## Troubleshooting

### Mistake in Release Tag

If you tagged the wrong version:

```bash
# Delete local tag
git tag -d v1.0.0-alpha.2

# Delete remote tag
git push origin :refs/tags/v1.0.0-alpha.2

# Recreate correctly
git tag -a v1.0.0-alpha.2 -m "Correct message"
git push origin v1.0.0-alpha.2
```

### Need to Undo Merge to Main

If merge hasn't been pushed yet:

```bash
git checkout main
git reset --hard HEAD~1
```

If already pushed (use with caution):

```bash
git checkout main
git revert -m 1 HEAD
git push origin main
```

### Forgot to Update VERSION File

If you realize after tagging:

```bash
# Don't delete tag, just fix in next commit
git checkout main
echo "1.0.0-alpha.2" > VERSION
git add VERSION
git commit -m "Fix: Update VERSION file for v1.0.0-alpha.2"
git push origin main

# Merge fix back to dev
git checkout dev
git merge main
```

---

**Questions or Issues?**

If you encounter problems with the release workflow, consult Git documentation or open a discussion on GitHub.
