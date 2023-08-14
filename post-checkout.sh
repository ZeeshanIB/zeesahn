bash
#!/bin/bash

current_branch=$(git branch --show-current)

if [ "$current_branch" == "master" ]; then
  # Replace 'instruction.txt' with the name of your instruction file
  cp -f instruction.txt shared-repo-test/instruction.txt
  git add path/to/directory/instruction.txt
fi

exit 0