const fs = require('fs')

const maxOutputLength = 200000
const stepOutcomeIcons = {
  success: '🟢',
  failure: '🔴',
  skipped: '⚪',
  pending: '🟡',
  unknown: '❔',
}

const buildComment = ({context, core, command, appName, steps}) => {
  const filePath = `/tmp/${context.runId}.comment.txt`

  const commentBody = '### ' + command + ': `' + appName + '`\n\n' +
    steps.map(step => buildStep(context, core, step)).join('\n\n') +
    `

---
[View the run details](${fetchJobLink(context)})`

  core.debug(`Comment: ${commentBody}`)

  try {
    fs.writeFileSync(filePath, commentBody)
  } catch (err) {
    core.setFailed(`Failed to write comment to ${filePath}: ${err}`)
  }

  return filePath
}

const buildStep = (context, core, step) => {
  const stepName = step.name
  const outcome =
    step.outcome ||
    process.env[`STEP_${stepName.toUpperCase()}_OUTCOME`] ||
    'unknown'
  const outcomeIcon = stepOutcomeIcons[outcome] || stepOutcomeIcons.unknown
  const stepOutput = buildStepOutput(context, core, stepName)

  const stepSummaryText = `${outcomeIcon} <strong>${stepName}</strong>`

  if (stepOutput) {
    return `<details>
<summary>${stepSummaryText}</summary>

~~~
${stepOutput.trim()}
~~~
</details>`
  }

  return stepSummaryText
}

const buildStepOutput = (context, core, stepName) => {
  try {
    let output = fs.readFileSync(`/tmp/${context.runId}.${stepName}.txt`, 'utf8')

    if (output.length > maxOutputLength) {
      output = output.slice(-(maxOutputLength - 100))
      output += '\n\n---\n\nOutput too long and has been truncated. View the full logs in GitHub actions.'
    }

    return output
  } catch (err) {
    core.warning(`Failed to read output of step ${stepName}: ${err}`)
    return ''
  }
}

const fetchJobLink = (context) => {
  return `https://github.com/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}?check_suite_focus=true`
}

module.exports = {
  buildComment,
}
