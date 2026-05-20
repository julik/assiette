import {alpha} from "./mid/alpha.js"
import {beta} from "./mid/beta.js"
import {gamma} from "./mid/gamma.js"

export function initA() {
  return [alpha(), beta(), gamma()]
}

const result = initA()
console.log("root_a:" + JSON.stringify(result))

const el = document.createElement("p")
el.id = "js-status"
el.textContent = "JS modules loaded: " + JSON.stringify(result)
document.body.appendChild(el)
