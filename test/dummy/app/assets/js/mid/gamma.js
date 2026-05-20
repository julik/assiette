import {gammaOne} from "../leaf/gamma_one.js"
import {gammaTwo} from "../leaf/gamma_two.js"

export function gamma() {
  return [gammaOne(), gammaTwo()]
}
