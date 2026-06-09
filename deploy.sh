#!/bin/bash

git add .
git commit -m "revert: drop carb_effect kind (CarbMath static glucoseEffects is internal; carbs 
  already covered)"
git push -u origin main