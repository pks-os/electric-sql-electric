import 'animate.css/animate.min.css'
import Board from './pages/Board'
import { useEffect, useState, createContext } from 'react'
import { Route, Routes, BrowserRouter } from 'react-router-dom'
import { cssTransition, ToastContainer } from 'react-toastify'
import 'react-toastify/dist/ReactToastify.css'
import List from './pages/List'
import Issue from './pages/Issue'
import LeftMenu from './components/LeftMenu'

import { ElectricProvider, initElectric, dbName } from './electric'
import { Electric } from './generated/client'

interface MenuContextInterface {
  showMenu: boolean
  setShowMenu: (show: boolean) => void
}

export const MenuContext = createContext(null as MenuContextInterface | null)

const slideUp = cssTransition({
  enter: 'animate__animated animate__slideInUp',
  exit: 'animate__animated animate__slideOutDown',
})

function deleteDB() {
  console.log("Deleting DB as schema doesn't match server's")
  const DBDeleteRequest = window.indexedDB.deleteDatabase(dbName)
  DBDeleteRequest.onsuccess = function () {
    console.log('Database deleted successfully')
  }
  // the indexedDB cannot be deleted if the database connection is still open,
  // so we need to reload the page to close any open connections.
  // On reload, the database will be recreated.
  window.location.reload()
}

const App = () => {
  const [electric, setElectric] = useState<Electric>()
  const [showMenu, setShowMenu] = useState(false)

  useEffect(() => {
    const init = async () => {
      let client
      try {
        client = await initElectric()
      } catch (error) {
        console.log('here')
        console.log((error as Error).message)
        if (
          (error as Error).message.startsWith(
            "Local schema doesn't match server's"
          )
        ) {
          deleteDB()
        }
        throw error
      }
      setElectric(client)
      const { synced } = await client.db.issue.sync({
        include: {
          comment: true,
        },
      })
      await synced
    }

    init()
  }, [])

  if (electric === undefined) {
    return null
  }

  const router = (
    <Routes>
      <Route path="/" element={<List />} />
      <Route path="/search" element={<List showSearch={true} />} />
      <Route path="/board" element={<Board />} />
      <Route path="/issue/:id" element={<Issue />} />
    </Routes>
  )

  return (
    <ElectricProvider db={electric}>
      <MenuContext.Provider value={{ showMenu, setShowMenu }}>
        <BrowserRouter>
          <div className="flex w-full h-screen overflow-y-hidden">
            <LeftMenu />
            {router}
          </div>
          <ToastContainer
            position="bottom-right"
            autoClose={5000}
            hideProgressBar
            newestOnTop
            closeOnClick
            rtl={false}
            transition={slideUp}
            pauseOnFocusLoss
            draggable
            pauseOnHover
          />
        </BrowserRouter>
      </MenuContext.Provider>
    </ElectricProvider>
  )
}

export default App