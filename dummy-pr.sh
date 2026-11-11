set -e
BRANCH="dummy-$(date +%Y.%m.%d-%s)"
git fetch origin master && git checkout -b $BRANCH FETCH_HEAD
touch ${BRANCH}
git add ${BRANCH} && git commit -m "chore: Dummy PR to retrigger CI"
git rm ${BRANCH} && git commit -m "chore: Dummy PR to retrigger CI"
git push fork $BRANCH --force
